import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 対象に加えるときの GitHub 側の準備（`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）を、管理用のトークンで流し、
/// `repo.json` の `setup` に書く。`addRepository` を処理したとき（加え直した・準備をやり直すときも）に呼ぶ。
///
/// 管理用のトークンが無ければ、準備だけを止めて理由を書く（加えるのは受け付ける。2026-11-13 にユーザーが決めた）
struct RepositorySetupStep {
    var admin: AdminGitHub
    /// app-kit を読む部品。nil（ワーカー・テスト）なら、app-kit への入れ替えを足さない
    var appKit: (any AppKitSource)?

    init(admin: AdminGitHub, appKit: (any AppKitSource)? = nil) {
        self.admin = admin
        self.appKit = appKit
    }

    func run(for repo: RepositoryFullName, in context: CommanderContext) async throws(CommanderError) {
        let path = StatePath.repository(repo)
        guard let file = try await context.read(RepositoryFile.self, at: path) else { return }
        let setup: RepositorySetup
        var installed: RepositoryFile.AppKit?
        switch await admin.pullRequests(for: repo, now: context.now()) {
        case let .failure(refusal):
            // 前に出した準備の PR の記録は残す（消すと、その PR の承認を断ることになる）
            setup = RepositorySetup(updatedAt: context.timestamp, workflows: file.setup?.workflows, problems: [refusal.description])
        case let .success(github):
            let input = try await appKitInput(for: file, in: context)
            let outcome = await RepositorySetupRunner(github: github, now: context.timestamp, appKit: input)
                .run(build: file.build, previous: file.setup?.workflows)
            if let wait = outcome.stoppedFor { await admin.pause(repo.owner, for: wait, now: context.now()) }
            setup = outcome.setup
            installed = outcome.installedAppKit
        }
        do {
            try await context.files.update(RepositoryFile.self, at: path, message: "\(repo) の GitHub 側の準備を書く") {
                $0.setup = setup
                // もう app-kit を呼んでいる（テンプレートから作った・手で入れ替えた）なら、呼んでいる版を書く
                if $0.appKit == nil, let installed { $0.appKit = installed }
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    /// app-kit への入れ替えに使うもの。もう入っている・app-kit を読む部品が無いなら nil
    private func appKitInput(for file: RepositoryFile, in context: CommanderContext) async throws(CommanderError) -> AppKitInput? {
        guard file.appKit == nil, let appKit else { return nil }
        let state = try await context.readable(AppKitFile.self, at: StatePath.appKit)
        let applied = file.protection.appliedAt != nil
        let requiredChecks = applied ? file.protection.requiredChecks ?? ProtectionPolicy.defaultRequiredChecks : []
        var input = AppKitInput(releases: state?.releases ?? [], requiredChecks: requiredChecks)
        guard let adoption = state?.adoption else {
            input.problem = "司令塔がまだ app-kit の版を読んでいないので、app-kit への入れ替えは足さなかった（少し待ってから準備をやり直す）"
            return input
        }
        do throws(AppKitSourceError) {
            input.release = try await appKit.release(adoption)
        } catch {
            input.problem = "\(error.description)。app-kit への入れ替えは足さなかった（準備をやり直すと、もう一度読む）"
        }
        return input
    }
}

/// app-kit への入れ替えに使うもの
struct AppKitInput {
    /// 入れる版の中身。読めなかったら nil（理由は `problem`）
    var release: AppKitRelease?
    /// 見つけた版（呼んでいるコミットから版のタグを引く）
    var releases: [AppKitFile.Release]
    /// 掛けた保護の必須のチェック（掛けていなければ空）
    var requiredChecks: [String]
    var problem: String?

    init(release: AppKitRelease? = nil, releases: [AppKitFile.Release] = [], requiredChecks: [String] = [], problem: String? = nil) {
        self.release = release
        self.releases = releases
        self.requiredChecks = requiredChecks
        self.problem = problem
    }
}

/// 準備の中身（Discussions・ワークフローの直しの PR）。1 つが失敗しても、ほかは流す（GitHub の上限に当たったら、続けて送らずに止める）
struct RepositorySetupRunner {
    struct Outcome {
        var setup: RepositorySetup
        /// GitHub の上限に当たり、残りを確かめずに止めた（待つ時間）。上限でなければ nil
        var stoppedFor: Duration?
        /// もう app-kit を呼んでいたなら、呼んでいる版
        var installedAppKit: RepositoryFile.AppKit?
    }

    /// ワークフローの直しを確かめた結果
    struct Checked {
        var setup: WorkflowSetup
        var problems: [String] = []
        var installedAppKit: RepositoryFile.AppKit?
    }

    var github: GitHubPullRequests
    var now: Timestamp
    var appKit: AppKitInput?

    init(github: GitHubPullRequests, now: Timestamp, appKit: AppKitInput? = nil) {
        self.github = github
        self.now = now
        self.appKit = appKit
    }

    func run(build: RepositoryFile.Build?, previous: WorkflowSetup?) async -> Outcome {
        let settings: RepositorySettings
        do throws(PullRequestError) {
            settings = try await github.repositorySettings()
        } catch {
            let problems = [Self.reason("リポジトリの設定を読めない", error)]
            return Outcome(setup: RepositorySetup(updatedAt: now, workflows: previous, problems: problems), stoppedFor: error.wait)
        }
        var setup = RepositorySetup(updatedAt: now)
        var problems: [String] = []
        var stoppedFor: Duration?
        var installed: RepositoryFile.AppKit?
        do throws(PullRequestError) {
            if !settings.hasDiscussions { try await github.enableDiscussions() }
            let categories = try await github.discussionCategoryNames()
            setup.discussions = categories.contains(SetupPolicy.discussionCategory) ? .ready : .missingCategory
        } catch {
            setup.discussions = .unknown
            problems.append(Self.reason("Discussions を有効にできない・確かめられない", error))
            stoppedFor = error.wait
        }
        if let wait = stoppedFor {
            // 前に出した PR の記録は残す
            setup.workflows = previous
            problems.append("GitHub の上限に当たったので、ワークフローの直しは確かめずに止めた（\(wait.components.seconds) 秒ほど待ってから準備をやり直す）")
        } else {
            do throws(PullRequestError) {
                let checked = try await workflows(base: build?.baseBranch ?? settings.defaultBranch, build: build, previous: previous)
                setup.workflows = checked.setup
                problems += checked.problems
                installed = checked.installedAppKit
            } catch {
                // 前に出した PR の記録は残す
                setup.workflows = previous
                problems.append(Self.reason("ワークフローの直しの PR を出せない", error))
                stoppedFor = error.wait
            }
        }
        setup.problems = problems.isEmpty ? nil : problems
        return Outcome(setup: setup, stoppedFor: stoppedFor, installedAppKit: installed)
    }

    /// 直すところがあれば、決まった手順の PR を出す。前に出した PR が開いていれば、出し直さない。
    /// どのワークフローにも見つからない待つチェックと、app-kit に入れ替えられないわけも返す
    func workflows(base: String, build: RepositoryFile.Build?, previous: WorkflowSetup?) async throws(PullRequestError) -> Checked {
        if let open = try await github.openPullRequest(head: SetupPolicy.workflowBranch, base: base) {
            let same = previous?.pullRequest == open.number
            let setup = WorkflowSetup(
                state: .open,
                pullRequest: open.number,
                head: open.headSHA,
                changes: same ? previous?.changes ?? [] : [],
                appKit: same ? previous?.appKit : nil
            )
            return Checked(setup: setup)
        }
        // 読んだ中身と直しのコミットの親を、同じコミットにそろえる（読んだ後に base が進んでも、古い中身で上書きしない）
        guard let head = try await github.branchHead(base) else { throw .notFound }
        let files = try await github.workflowFiles(ref: head)
        var checked = Checked(setup: WorkflowSetup(state: .notNeeded))
        let adoption = try await adoptionPlan(files: files, head: head, build: build, into: &checked)
        let plan: WorkflowSetupEditor.Plan
        if adoption.adoption == nil {
            plan = WorkflowSetupEditor.plan(files, waitedJobs: WorkflowSetupEditor.waitedJobs(of: build))
            checked.problems += plan.unresolvedJobs.map(Self.unresolved)
        } else {
            // 入れ替えると、待つチェックは写すファイルの build.yml が出す。残るワークフローからは、今の仕組みのものだけを外す
            plan = WorkflowSetupEditor.plan(files.filter { adoption.changes[$0.path] == nil }, waitedJobs: [])
        }
        let changes = plan.changes.merging(adoption.changes) { _, adopted in adopted }
        let summary = adoption.summary + plan.summary
        guard !changes.isEmpty else { return checked }
        let version = adoption.adoption?.version
        _ = try await github.commitChanges(changes, onto: head, branch: SetupPolicy.workflowBranch, message: Self.commitMessage(version))
        let body = Self.body(summary, adoption: adoption.adoption)
        let draft = PullRequestDraft(base: base, head: SetupPolicy.workflowBranch, title: Self.title(version), body: body)
        let opened = try await github.openPullRequest(draft).pullRequest
        checked.setup = WorkflowSetup(
            state: .open, pullRequest: opened.number, head: opened.headSHA, changes: summary, appKit: adoption.adoption
        )
        return checked
    }

    /// app-kit への入れ替えの中身。もう app-kit を呼んでいれば、呼んでいる版を `checked` に書いて何も変えない
    private func adoptionPlan(
        files: [WorkflowFile],
        head: String,
        build: RepositoryFile.Build?,
        into checked: inout Checked
    ) async throws(PullRequestError) -> AppKitAdoptionPlanner.Plan {
        guard let appKit else { return .init() }
        if let ref = AppKitCaller.ref(in: files) {
            checked.installedAppKit = RepositoryFile.AppKit(ref: ref, version: appKit.releases.first { $0.ref == ref }?.version)
            return .init()
        }
        guard let release = appKit.release else {
            checked.problems += appKit.problem.map { [$0] } ?? []
            return .init()
        }
        let tree = try await github.files(at: head)
        let wanted = Set(release.manifest.replaces.map(\.path) + [AppKitPolicy.configPath])
        let present = tree.filter { wanted.contains($0.path) && $0.type == "blob" }
        let blobs = try await github.blobTexts(present.map(\.sha))
        var texts: [String: String] = [:]
        for file in present {
            if case let .some(.some(text)) = blobs[file.sha] { texts[file.path] = text }
        }
        let waited = (build.map { $0.childChecks + $0.finalChecks } ?? ProtectionPolicy.defaultRequiredChecks) + appKit.requiredChecks
        let plan = AppKitAdoptionPlanner.plan(release: release, files: tree, texts: texts, build: build, waitedChecks: waited)
        checked.problems += plan.problems
        return plan
    }

    /// 待つチェックを出すジョブが見つからないときの問題（絞りを外せたかを確かめられない）
    static func unresolved(_ job: String) -> String {
        "待つチェック \(job) を出すジョブがワークフローに見つからない。そのワークフローの paths・paths-ignore を人が確かめる"
    }

    static func commitMessage(_ version: AppKitVersion?) -> String {
        guard let version else { return "[ci] AskHub の準備として、待つチェックのワークフローと今の仕組みのワークフローを直す" }
        return "[ci] AskHub の準備として、CI・リリースのワークフローを app-kit \(version) に入れ替える"
    }

    static func title(_ version: AppKitVersion?) -> String {
        guard let version else { return "【CI】AskHub の準備: 待つチェックのワークフローを直し、今の仕組みのワークフローを外す" }
        return "【CI】AskHub の準備: CI・リリースのワークフローを app-kit \(version) に入れ替える"
    }

    static func body(_ changes: [WorkflowChange], adoption: AppKitAdoption? = nil) -> String {
        var sections = adoption.map { adoptionSections(changes, adoption: $0) } ?? []
        let others = changes.compactMap { change -> String? in
            switch change.kind {
            case .removeLegacy: "- `\(change.path)` を外す（今の仕組みのワークフロー）"
            case .removePathFilters: "- `\(change.path)` の `paths`・`paths-ignore` を外す（AskHub のワーカーが待つチェックを、ドキュメントだけの変更でも出す）"
            case .adoptAppKit, .removeReplaced: nil
            }
        }
        if !others.isEmpty { sections.append((adoption == nil ? "" : "### そのほかの直し\n\n") + others.joined(separator: "\n")) }
        return """
            AskHub の司令塔が、対象に加えるときの決まった手順で出した PR です（`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）。

            \(sections.joined(separator: "\n\n"))

            ワーカーのトークンはワークフローのファイルを書けないので、司令塔の管理用のトークンで出しています。
            AskHub のアプリのリポジトリの画面で承認すると、司令塔がこの head のままマージします（承認の後に push された変更はマージしません）。
            """
    }

    /// app-kit への入れ替えの節（足すファイル・外すファイル・待つチェックの名前）
    private static func adoptionSections(_ changes: [WorkflowChange], adoption: AppKitAdoption) -> [String] {
        var sections: [String] = []
        let link = "[app-kit](https://github.com/\(AppKitPolicy.repository.rawValue)/tree/\(adoption.ref))"
        sections.append("CI・リリースのワークフローを、共通リポジトリ \(link) の \(adoption.version)（`\(adoption.ref)`）を呼ぶ形に入れ替えます。")
        let added = changes.filter { $0.kind == .adoptAppKit }.map { "- `\($0.path)`" }
        if !added.isEmpty { sections.append("### 足す・app-kit の中身にするファイル\n\n" + added.joined(separator: "\n")) }
        let removed = changes.filter { $0.kind == .removeReplaced }.map(removedLine)
        if !removed.isEmpty {
            sections.append("### 外すファイル（app-kit に置き換わる）\n\n" + removed.joined(separator: "\n")
                + "\n\n「app-kit に無い手順」は、外すワークフローにしか無い手順です。要るものは、app-kit の設定に足すか、このリポジトリだけのワークフローとして残します。")
        }
        if let renames = adoption.renamedChecks {
            sections.append("### 待つチェックの名前\n\n" + renames.map { "- `\($0.from)` → `\($0.to)`" }.joined(separator: "\n")
                + "\n\n承認されたら、司令塔がマージの前に、ルールセットの必須のチェック（掛けていれば）とビルドの設定を新しい名前に替えます。")
        }
        return sections
    }

    private static func removedLine(_ change: WorkflowChange) -> String {
        var line = "- `\(change.path)`"
        if let lines = change.lines { line += "（\(lines) 行）" }
        if let steps = change.steps { line += "。app-kit に無い手順: " + steps.joined(separator: "・") }
        return line
    }

    static func reason(_ what: String, _ error: PullRequestError) -> String {
        switch error {
        case .notFound: "\(what)（見つからない。管理用のトークンの Repository access に入っているかを確かめる）"
        case .unauthorized: "\(what)（管理用のトークンが使えない。期限切れ・取り消し）"
        case let .forbidden(message): "\(what)（管理用のトークンで断られた。権限を確かめる。GitHub: \(message ?? "")）"
        default: "\(what)（\(error)）"
        }
    }
}

/// ワークフローを直す PR のマージの承認（`approveSetupPullRequest`）を受け付け、管理用のトークンで、承認した head のままマージする。
///
/// app-kit に入れ替える PR で、待つチェックの名前が変わるなら、マージの前にルールセットの必須のチェックとビルドの設定を新しい名前に替える
/// （古い名前のチェックは入れ替えた PR に出ないので、替えないとマージできない）。マージしたら `repo.json` の `appKit` に入れた版を書く
public struct ApproveSetupPullRequestHandler: IntentHandler {
    public var admin: AdminGitHub?

    public init(admin: AdminGitHub?) {
        self.admin = admin
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let approve: ApproveSetupPullRequestIntent
        do {
            approve = try ApproveSetupPullRequestIntent(envelope: envelope)
        } catch {
            return .reject("準備の PR の承認の形が違う（\(error.detail)）")
        }
        let path = StatePath.repository(approve.repo)
        guard let file = try await context.read(RepositoryFile.self, at: path) else {
            return .reject("\(approve.repo) は対象のリポジトリに加えていない")
        }
        guard let workflows = file.setup?.workflows, workflows.pullRequest == approve.pullRequest else {
            return .reject("PR #\(approve.pullRequest) は、司令塔が出した準備の PR でない")
        }
        if workflows.state == .merged { return .accept }
        guard workflows.state == .open, workflows.head == approve.head else {
            return .reject("承認したときと準備の PR が違う（今は \(workflows.state.rawValue)）。見直して承認し直す")
        }
        guard let admin else { return .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）") }
        let github: GitHubPullRequests
        switch await admin.pullRequests(for: approve.repo, now: context.now()) {
        case let .success(made): github = made
        case let .failure(refusal): return .reject(refusal.description)
        }
        if let refusal = await renaming(workflows.appKit?.renamedChecks, of: file, with: github, admin: admin, in: context) {
            return refusal
        }
        let state: WorkflowSetup.State
        do throws(PullRequestError) {
            state = try await merge(approve, with: github)
        } catch {
            await admin.note(error, owner: approve.repo.owner, now: context.now())
            return .reject(Self.reason(error))
        }
        try await record(state, of: approve, adopting: workflows.appKit, at: path, in: context)
        return state == .merged ? .accept : .reject("準備の PR は、マージされずに閉じられている")
    }

    /// 名前が変わる待つチェックがあれば替える。替えられなければ、断るわけ
    private func renaming(
        _ renames: [CheckRename]?,
        of file: RepositoryFile,
        with github: GitHubPullRequests,
        admin: AdminGitHub,
        in context: CommanderContext
    ) async -> IntentDecision? {
        guard let renames else { return nil }
        do throws(PullRequestError) {
            try await rename(renames, of: file, with: github, at: StatePath.repository(file.repo), in: context)
            return nil
        } catch {
            await admin.note(error, owner: file.repo.owner, now: context.now())
            return .reject(Self.reason(error, renaming: renames))
        }
    }

    /// 待つチェックの名前を替える。掛けた保護のルールセットを先に替え、替えられたらビルドの設定と保護の記録を書く。
    /// もう替えてあれば何もしない（マージできずに承認し直したとき）
    private func rename(
        _ renames: [CheckRename],
        of file: RepositoryFile,
        with github: GitHubPullRequests,
        at path: String,
        in context: CommanderContext
    ) async throws(PullRequestError) {
        let required = file.protection.requiredChecks ?? ProtectionPolicy.defaultRequiredChecks
        let renamedRequired = AppKitAdoptionPlanner.renaming(required, with: renames)
        var applied: Int?
        if file.protection.appliedAt != nil, renamedRequired != required {
            applied = try await github.putRuleset(ProtectionRules.draft(requiredChecks: renamedRequired), id: file.protection.rulesetId).id
        }
        do {
            let message = "\(file.repo) の待つチェックの名前を app-kit に入れ替えた後の名前に替えた"
            try await context.files.update(RepositoryFile.self, at: path, message: message) { current in
                var changed = false
                if var build = current.build {
                    build.childChecks = AppKitAdoptionPlanner.renaming(build.childChecks, with: renames)
                    build.finalChecks = AppKitAdoptionPlanner.renaming(build.finalChecks, with: renames)
                    if build != current.build {
                        current.build = build
                        changed = true
                    }
                }
                if let applied {
                    current.protection.requiredChecks = renamedRequired
                    current.protection.rulesetId = applied
                    changed = true
                }
                return changed
            }
        } catch {
            throw .malformed("待つチェックの名前を状態リポジトリに書けない（\(error)）")
        }
    }

    /// 承認した head のままマージする。すでにマージ・閉じていれば、その様子を返す
    private func merge(
        _ approve: ApproveSetupPullRequestIntent,
        with github: GitHubPullRequests
    ) async throws(PullRequestError) -> WorkflowSetup.State {
        let current = try await github.pullRequest(number: approve.pullRequest)
        if current.merged { return .merged }
        guard current.state == .open else { return .closed }
        guard current.headSHA == approve.head else { throw .headChanged }
        _ = try await github.merge(number: approve.pullRequest, headSHA: approve.head)
        return .merged
    }

    private func record(
        _ state: WorkflowSetup.State,
        of approve: ApproveSetupPullRequestIntent,
        adopting adoption: AppKitAdoption?,
        at path: String,
        in context: CommanderContext
    ) async throws(CommanderError) {
        do {
            let message = "\(approve.repo) の準備の PR を\(state == .merged ? "マージした" : "閉じた")"
            let now = context.timestamp
            try await context.files.update(RepositoryFile.self, at: path, message: message) {
                guard $0.setup?.workflows?.pullRequest == approve.pullRequest, $0.setup?.workflows?.state != state else { return false }
                $0.setup?.workflows?.state = state
                if state == .merged, let adoption {
                    $0.appKit = RepositoryFile.AppKit(ref: adoption.ref, version: adoption.version, installedAt: now)
                }
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    static func reason(_ error: PullRequestError, renaming renames: [CheckRename]) -> String {
        let names = renames.map { "\($0.from) → \($0.to)" }.joined(separator: "・")
        return RepositorySetupRunner.reason("マージの前に待つチェックの名前（\(names)）を替えられない", error) + "。マージしていない"
    }

    static func reason(_ error: PullRequestError) -> String {
        switch error {
        case .headChanged: "承認した後に準備の PR が更新された。見直して承認し直す"
        case let .notMergeable(message): "まだマージできない（必須のチェックが通っていない・コンフリクトなど。GitHub: \(message ?? "")）。CI が通ってから承認し直す"
        case .rateLimited, .serverError, .transport, .cancelled: "GitHub に届かない・混んでいる（\(error)）。少し待ってから承認し直す"
        default: RepositorySetupRunner.reason("準備の PR をマージできない", error)
        }
    }
}

private extension PullRequestError {
    /// 上限なら、待つ時間
    var wait: Duration? {
        if case let .rateLimited(wait) = self { return wait }
        return nil
    }
}
