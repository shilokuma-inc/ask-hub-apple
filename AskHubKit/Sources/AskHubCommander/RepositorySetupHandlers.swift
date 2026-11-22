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

    func run(for repo: RepositoryFullName, in context: CommanderContext) async throws(CommanderError) {
        let path = StatePath.repository(repo)
        guard let file = try await context.read(RepositoryFile.self, at: path) else { return }
        let setup: RepositorySetup
        switch await admin.pullRequests(for: repo, now: context.now()) {
        case let .failure(refusal):
            // 前に出した準備の PR の記録は残す（消すと、その PR の承認を断ることになる）
            setup = RepositorySetup(updatedAt: context.timestamp, workflows: file.setup?.workflows, problems: [refusal.description])
        case let .success(github):
            let outcome = await RepositorySetupRunner(github: github, now: context.timestamp)
                .run(build: file.build, previous: file.setup?.workflows)
            if let wait = outcome.stoppedFor { await admin.pause(repo.owner, for: wait, now: context.now()) }
            setup = outcome.setup
        }
        do {
            try await context.files.update(RepositoryFile.self, at: path, message: "\(repo) の GitHub 側の準備を書く") {
                $0.setup = setup
                return true
            }
        } catch {
            throw .files(error)
        }
    }
}

/// 準備の中身（Discussions・ワークフローの直しの PR）。1 つが失敗しても、ほかは流す（GitHub の上限に当たったら、続けて送らずに止める）
struct RepositorySetupRunner {
    struct Outcome {
        var setup: RepositorySetup
        /// GitHub の上限に当たり、残りを確かめずに止めた（待つ時間）。上限でなければ nil
        var stoppedFor: Duration?
    }

    var github: GitHubPullRequests
    var now: Timestamp

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
                problems += checked.unresolvedJobs.map(Self.unresolved)
            } catch {
                // 前に出した PR の記録は残す
                setup.workflows = previous
                problems.append(Self.reason("ワークフローの直しの PR を出せない", error))
                stoppedFor = error.wait
            }
        }
        setup.problems = problems.isEmpty ? nil : problems
        return Outcome(setup: setup, stoppedFor: stoppedFor)
    }

    /// 直すところがあれば、決まった手順の PR を出す。前に出した PR が開いていれば、出し直さない。
    /// どのワークフローにも見つからない待つチェックも返す
    func workflows(
        base: String,
        build: RepositoryFile.Build?,
        previous: WorkflowSetup?
    ) async throws(PullRequestError) -> (setup: WorkflowSetup, unresolvedJobs: [String]) {
        if let open = try await github.openPullRequest(head: SetupPolicy.workflowBranch, base: base) {
            let changes = previous?.pullRequest == open.number ? previous?.changes ?? [] : []
            return (WorkflowSetup(state: .open, pullRequest: open.number, head: open.headSHA, changes: changes), [])
        }
        // 読んだ中身と直しのコミットの親を、同じコミットにそろえる（読んだ後に base が進んでも、古い中身で上書きしない）
        guard let head = try await github.branchHead(base) else { throw .notFound }
        let files = try await github.workflowFiles(ref: head)
        let plan = WorkflowSetupEditor.plan(files, waitedJobs: WorkflowSetupEditor.waitedJobs(of: build))
        guard !plan.isEmpty else { return (WorkflowSetup(state: .notNeeded), plan.unresolvedJobs) }
        _ = try await github.commitChanges(plan.changes, onto: head, branch: SetupPolicy.workflowBranch, message: Self.commitMessage)
        let draft = PullRequestDraft(base: base, head: SetupPolicy.workflowBranch, title: Self.title, body: Self.body(plan.summary))
        let opened = try await github.openPullRequest(draft).pullRequest
        return (WorkflowSetup(state: .open, pullRequest: opened.number, head: opened.headSHA, changes: plan.summary), plan.unresolvedJobs)
    }

    /// 待つチェックを出すジョブが見つからないときの問題（絞りを外せたかを確かめられない）
    static func unresolved(_ job: String) -> String {
        "待つチェック \(job) を出すジョブがワークフローに見つからない。そのワークフローの paths・paths-ignore を人が確かめる"
    }

    static let commitMessage = "[ci] AskHub の準備として、待つチェックのワークフローと今の仕組みのワークフローを直す"
    static let title = "【CI】AskHub の準備: 待つチェックのワークフローを直し、今の仕組みのワークフローを外す"

    static func body(_ changes: [WorkflowChange]) -> String {
        let lines = changes.map { change in
            switch change.kind {
            case .removeLegacy: "- `\(change.path)` を外す（今の仕組みのワークフロー）"
            case .removePathFilters: "- `\(change.path)` の `paths`・`paths-ignore` を外す（AskHub のワーカーが待つチェックを、ドキュメントだけの変更でも出す）"
            case .adoptAppKit: "- `\(change.path)` を app-kit の版の中身にする"
            case .removeReplaced: "- `\(change.path)` を外す（app-kit に置き換わる）"
            }
        }
        return """
            AskHub の司令塔が、対象に加えるときの決まった手順で出した PR です（`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）。

            \(lines.joined(separator: "\n"))

            ワーカーのトークンはワークフローのファイルを書けないので、司令塔の管理用のトークンで出しています。
            AskHub のアプリのリポジトリの画面で承認すると、司令塔がこの head のままマージします（承認の後に push された変更はマージしません）。
            """
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

/// ワークフローを直す PR のマージの承認（`approveSetupPullRequest`）を受け付け、管理用のトークンで、承認した head のままマージする
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
        let state: WorkflowSetup.State
        do throws(PullRequestError) {
            state = try await merge(approve, with: github)
        } catch {
            await admin.note(error, owner: approve.repo.owner, now: context.now())
            return .reject(Self.reason(error))
        }
        try await record(state, of: approve, at: path, in: context)
        return state == .merged ? .accept : .reject("準備の PR は、マージされずに閉じられている")
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
        at path: String,
        in context: CommanderContext
    ) async throws(CommanderError) {
        do {
            let message = "\(approve.repo) の準備の PR を\(state == .merged ? "マージした" : "閉じた")"
            try await context.files.update(RepositoryFile.self, at: path, message: message) {
                guard $0.setup?.workflows?.pullRequest == approve.pullRequest, $0.setup?.workflows?.state != state else { return false }
                $0.setup?.workflows?.state = state
                return true
            }
        } catch {
            throw .files(error)
        }
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
