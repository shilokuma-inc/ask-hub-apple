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
        switch admin.pullRequests(for: repo) {
        case let .failure(problem):
            setup = RepositorySetup(updatedAt: context.timestamp, problems: [problem.description])
        case let .success(github):
            setup = await RepositorySetupRunner(github: github, now: context.timestamp)
                .run(build: file.build, previous: file.setup?.workflows)
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

/// 準備の中身（Discussions・ワークフローの直しの PR）。1 つが失敗しても、ほかは流す
struct RepositorySetupRunner {
    var github: GitHubPullRequests
    var now: Timestamp

    func run(build: RepositoryFile.Build?, previous: WorkflowSetup?) async -> RepositorySetup {
        let settings: RepositorySettings
        do throws(PullRequestError) {
            settings = try await github.repositorySettings()
        } catch {
            return RepositorySetup(updatedAt: now, problems: [Self.reason("リポジトリの設定を読めない", error)])
        }
        var setup = RepositorySetup(updatedAt: now)
        var problems: [String] = []
        do throws(PullRequestError) {
            if !settings.hasDiscussions { try await github.enableDiscussions() }
            let categories = try await github.discussionCategoryNames()
            setup.discussions = categories.contains(SetupPolicy.discussionCategory) ? .ready : .missingCategory
        } catch {
            setup.discussions = .unknown
            problems.append(Self.reason("Discussions を有効にできない・確かめられない", error))
        }
        do throws(PullRequestError) {
            setup.workflows = try await workflows(base: build?.baseBranch ?? settings.defaultBranch, build: build, previous: previous)
        } catch {
            problems.append(Self.reason("ワークフローの直しの PR を出せない", error))
        }
        setup.problems = problems.isEmpty ? nil : problems
        return setup
    }

    /// 直すところがあれば、決まった手順の PR を出す。前に出した PR が開いていれば、出し直さない
    func workflows(base: String, build: RepositoryFile.Build?, previous: WorkflowSetup?) async throws(PullRequestError) -> WorkflowSetup {
        if let open = try await github.openPullRequest(head: SetupPolicy.workflowBranch, base: base) {
            let changes = previous?.pullRequest == open.number ? previous?.changes ?? [] : []
            return WorkflowSetup(state: .open, pullRequest: open.number, head: open.headSHA, changes: changes)
        }
        let files = try await github.workflowFiles(ref: base)
        let plan = WorkflowSetupEditor.plan(files, waitedJobs: WorkflowSetupEditor.waitedJobs(of: build))
        guard !plan.isEmpty else { return WorkflowSetup(state: .notNeeded) }
        guard let head = try await github.branchHead(base) else { throw .notFound }
        _ = try await github.commitChanges(plan.changes, onto: head, branch: SetupPolicy.workflowBranch, message: Self.commitMessage)
        let draft = PullRequestDraft(base: base, head: SetupPolicy.workflowBranch, title: Self.title, body: Self.body(plan.summary))
        let opened = try await github.openPullRequest(draft).pullRequest
        return WorkflowSetup(state: .open, pullRequest: opened.number, head: opened.headSHA, changes: plan.summary)
    }

    static let commitMessage = "[ci] AskHub の準備として、待つチェックのワークフローと今の仕組みのワークフローを直す"
    static let title = "【CI】AskHub の準備: 待つチェックのワークフローを直し、今の仕組みのワークフローを外す"

    static func body(_ changes: [WorkflowChange]) -> String {
        let lines = changes.map { change in
            switch change.kind {
            case .removeLegacy: "- `\(change.path)` を外す（今の仕組みのワークフロー）"
            case .removePathFilters: "- `\(change.path)` の `paths`・`paths-ignore` を外す（AskHub のワーカーが待つチェックを、ドキュメントだけの変更でも出す）"
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
        switch admin.pullRequests(for: approve.repo) {
        case let .success(made): github = made
        case let .failure(problem): return .reject(problem.description)
        }
        let state: WorkflowSetup.State
        do throws(PullRequestError) {
            state = try await merge(approve, with: github)
        } catch {
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
