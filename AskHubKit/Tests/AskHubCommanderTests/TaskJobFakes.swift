import AskHubBuild
@testable import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os

/// テストの SHA（`c` を並べ、最後の 1 文字で見分ける）
func sha(_ mark: Character) -> String {
    String(repeating: "c", count: 39) + String(mark)
}

/// リモートのブランチと、手元に変更があるかだけを覚える git（作業場所のファイルには触れない）
final class FakeTaskGit: TaskGit {
    struct State {
        /// リモートのブランチ（名前 → 先頭）
        var remote: [String: String]
        /// 手元に、まだコミットしていない変更があるか（Claude が書いたら true にする）
        var dirty = false
        var commits: [String] = []
        var calls: [String] = []
        var pushFailure: WorkspaceError?
        /// `isAncestor` が true を返す組（"祖先..子孫"）
        var ancestors: Set<String> = []
    }

    static let directory = URL(fileURLWithPath: "/work/epics/01JCJ0A0000000000000000001/repository/askhub-sandbox")
    private let state: OSAllocatedUnfairLock<State>

    init(remote: [String: String]) {
        state = OSAllocatedUnfairLock(initialState: State(remote: remote))
    }

    func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var current: State { state.withLock { $0 } }

    func checkOutTask(_ repo: RepositoryFullName, epic: ULID, branches: TaskBranches) async throws(WorkspaceError) -> CheckedOutTask {
        let result = state.withLock { state -> Result<CheckedOutTask, WorkspaceError> in
            state.calls.append("checkOutTask \(branches.task)")
            state.dirty = false
            guard let base = state.remote[branches.epic] else { return .failure(.failed("作業ブランチ \(branches.epic) がリモートに無い")) }
            let remote = state.remote[branches.task]
            let head = remote ?? base
            let task = CheckedOutTask(repo: repo, directory: Self.directory, branches: branches, head: head, remoteHead: remote, base: base)
            return .success(task.with(facts: "Swift 6 で書く。"))
        }
        return try result.get()
    }

    func commitAndPush(_ task: CheckedOutTask, message: String) async throws(WorkspaceError) -> String? {
        let result = state.withLock { state -> Result<String?, WorkspaceError> in
            state.calls.append("commitAndPush")
            guard state.dirty else { return .success(nil) }
            if let failure = state.pushFailure { return .failure(failure) }
            state.dirty = false
            state.commits.append(message)
            let head = sha(Character(String(state.commits.count)))
            state.remote[task.branches.task] = head
            return .success(head)
        }
        return try result.get()
    }

    func isAncestor(_ ancestor: String, of descendant: String, in task: CheckedOutTask) async throws(WorkspaceError) -> Bool {
        state.withLock { $0.ancestors.contains("\(ancestor)..\(descendant)") }
    }

    func checkOutReview(
        _ repo: RepositoryFullName,
        epic: ULID,
        branches: TaskBranches,
        head: String
    ) async throws(WorkspaceError) -> ReviewCheckout {
        state.withLock { $0.calls.append("checkOutReview \(head)") }
        return ReviewCheckout(directory: Self.directory, diff: "+struct Ranking {}", stat: " Ranking.swift | 1 +", facts: "Swift 6 で書く。")
    }
}

extension CheckedOutTask {
    func with(facts: String) -> Self {
        var task = self
        task.facts = facts
        return task
    }
}

/// 決まった報告を順に返し、渡されたジョブを覚える（Claude とビルドの往復の代わり）
final class FakeTaskRunner: TaskRunning {
    struct Call: Equatable {
        var kind: JobKind
        var prompt: String
        var resume: String?
        var directory: URL
        var facts: String
    }

    struct State {
        var replies: [TaskReply]
        var calls: [Call] = []
        var targets: [BuildTarget] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Claude が作業場所を書き換えたことにする
    let onRun: @Sendable () -> Void

    init(_ replies: [TaskReply], onRun: @escaping @Sendable () -> Void = {}) {
        state = OSAllocatedUnfairLock(initialState: State(replies: replies))
        self.onRun = onRun
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var targets: [BuildTarget] { state.withLock { $0.targets } }

    func record(_ target: BuildTarget) {
        state.withLock { $0.targets.append(target) }
    }

    func run<Job: TaskJob>(_ job: Job, in workspace: TaskWorkspace) async -> TaskReply {
        onRun()
        return state.withLock { state in
            let call = Call(kind: Job.kind, prompt: job.prompt, resume: job.resume, directory: workspace.directory, facts: workspace.facts)
            state.calls.append(call)
            guard !state.replies.isEmpty else { return .failed(AttemptFailure(failureClass: .unexpected, message: "報告が無い"), TaskRun()) }
            return state.replies.removeFirst()
        }
    }

    static func done(
        _ summary: String = "RankingClient を足した。",
        session: String = "s-impl",
        decisions: [TaskReport.Decision] = []
    ) -> TaskReply {
        let run = TaskRun(session: ClaudeSession(id: session, model: "claude-opus-5-5", estimatedCostUsd: 0.4, calls: 3), roundTrips: 1)
        return .reported(TaskReport(outcome: .done, summary: summary, decisions: decisions, learnings: ["List の行は…"]), run)
    }
}

/// PR の操作の偽物。PR・チェックの様子・ログを覚え、受けた操作を残す
final class FakePullRequests: PullRequestOperations {
    struct State {
        var pulls: [Int: PullRequest] = [:]
        var nextNumber = 41
        var drafts: [PullRequestDraft] = []
        /// 読むたびに先頭から返す（最後の 1 つは残す）
        var checks: [CheckSummary] = [CheckSummary(verdict: .passed)]
        var policies: [CheckPolicy] = []
        var reruns: [Int] = []
        var logs: [Int: String] = [:]
        var merges: [(number: Int, head: String)] = []
        var deletions: [(branch: String, expected: String)] = []
        var mergeSHA = String(repeating: "e", count: 40)
        var deleteError: PullRequestError?
        /// ログを読むときに、先に投げる失敗（1 回ずつ使う）
        var logFailures: [PullRequestError] = []
        /// 子 PR を読むたびに呼ぶ（待つ間に PR が変わったことにする）
        var onRead: (@Sendable (inout PullRequest) -> Void)?
        /// commit status。読むたびに先頭から返す（最後の 1 つは残す）
        var statuses: [[CommitStatus]] = [[]]
        var statusReads = 0
        /// レビューの指摘（GitHub の部品と同じく、信用する書き手のものだけを返す）
        var feedback = ReviewFeedback(threads: [], reviews: [])
        var trusted: [TrustedAuthors] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ state: State = State()) {
        self.state = OSAllocatedUnfairLock(initialState: state)
    }

    func update(_ body: @Sendable (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var current: State { state.withLock { $0 } }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PullRequestError) -> OpenedPullRequest {
        state.withLock { state in
            let open = state.pulls.values.filter { $0.state == .open }
            if let existing = open.first(where: { $0.headRef == draft.head && $0.baseRef == draft.base }) {
                return OpenedPullRequest(pullRequest: existing, created: false)
            }
            state.drafts.append(draft)
            let pull = PullRequest(number: state.nextNumber, state: .open, merged: false, head: (draft.head, sha("1")), baseRef: draft.base)
            state.pulls[pull.number] = pull
            state.nextNumber += 1
            return OpenedPullRequest(pullRequest: pull, created: true)
        }
    }

    func pullRequest(number: Int) async throws(PullRequestError) -> PullRequest {
        let pull = state.withLock { state -> PullRequest? in
            guard var pull = state.pulls[number] else { return nil }
            state.onRead?(&pull)
            state.pulls[number] = pull
            return pull
        }
        guard let pull else { throw .notFound }
        return pull
    }

    func checks(at sha: String, policy: CheckPolicy) async throws(PullRequestError) -> CheckSummary {
        state.withLock { state in
            state.policies.append(policy)
            return state.checks.count > 1 ? state.checks.removeFirst() : state.checks[0]
        }
    }

    func rerunFailedJobs(runID: Int) async throws(PullRequestError) {
        state.withLock { $0.reruns.append(runID) }
    }

    func reviewFeedback(number: Int, trusted: TrustedAuthors) async throws(PullRequestError) -> ReviewFeedback {
        state.withLock { state in
            state.trusted.append(trusted)
            let isTrusted = { (login: String) in trusted.logins.contains(login.lowercased()) }
            let threads = state.feedback.threads.filter { $0.comments.first.map { isTrusted($0.author) } ?? false }
            return ReviewFeedback(threads: threads, reviews: state.feedback.reviews.filter { isTrusted($0.author) })
        }
    }

    func commitStatuses(at sha: String) async throws(PullRequestError) -> [CommitStatus] {
        state.withLock { state in
            state.statusReads += 1
            return state.statuses.count > 1 ? state.statuses.removeFirst() : state.statuses[0]
        }
    }

    func merge(
        number: Int,
        headSHA: String,
        commitTitle: String?,
        commitMessage: String?
    ) async throws(PullRequestError) -> MergedPullRequest {
        let result = state.withLock { state -> Result<MergedPullRequest, PullRequestError> in
            guard var pull = state.pulls[number] else { return .failure(.notFound) }
            guard pull.headSHA == headSHA else { return .failure(.headChanged) }
            state.merges.append((number, headSHA))
            pull.state = .closed
            pull.merged = true
            pull.mergeCommitSHA = state.mergeSHA
            state.pulls[number] = pull
            return .success(MergedPullRequest(sha: state.mergeSHA, mergedNow: true))
        }
        return try result.get()
    }

    func deleteBranch(_ branch: String, expectedSHA: String) async throws(PullRequestError) -> BranchDeletion {
        let result = state.withLock { state -> Result<BranchDeletion, PullRequestError> in
            state.deletions.append((branch, expectedSHA))
            if let error = state.deleteError { return .failure(error) }
            return .success(.deleted)
        }
        return try result.get()
    }

    func jobLog(jobID: Int) async throws(PullRequestError) -> String {
        let result = state.withLock { state -> Result<String, PullRequestError> in
            if !state.logFailures.isEmpty { return .failure(state.logFailures.removeFirst()) }
            return state.logs[jobID].map { .success($0) } ?? .failure(.notFound)
        }
        return try result.get()
    }
}

/// 待つたびに時計を進める（待った時間を覚える）
final class ClockSleeper: Sleeper {
    private let state: OSAllocatedUnfairLock<(now: Date, waits: [Duration])>

    init(now: Date) {
        state = OSAllocatedUnfairLock(initialState: (now, []))
    }

    var now: Date { state.withLock { $0.now } }
    var waits: [Duration] { state.withLock { $0.waits } }

    func sleep(for duration: Duration) async throws {
        state.withLock { state in
            state.waits.append(duration)
            state.now += TaskRunner.seconds(duration)
        }
    }
}

/// タスクのジョブのテストの下ごしらえ（状態リポジトリ・epic・ゴール・ジョブ・試行）
struct TaskJobFixture {
    static let repo = EpicHandlersTests.repo
    static let mac = MacName(rawValue: "macbook-a")!
    static let epic = ULID(rawValue: "01JCJ0A0000000000000000001")!
    static let start = Date(timeIntervalSince1970: 1_793_757_600)
    static let branches = TaskBranches(
        base: "develop",
        epic: "askhub/01JCJ0A0000000000000000001",
        task: "askhub/01JCJ0A0000000000000000001-t2"
    )
    static let base = sha("b")

    let store = InMemoryStateStore()
    let git = FakeTaskGit(remote: ["askhub/01JCJ0A0000000000000000001": TaskJobFixture.base])
    let pulls = FakePullRequests()
    let sleeper = ClockSleeper(now: TaskJobFixture.start)
    let reviewer: ScriptedRunner

    init(reviews: [CommandResult] = []) {
        reviewer = ScriptedRunner(reviews)
    }

    var context: CommanderContext {
        CommanderContext(store: store, mac: Self.mac) { [sleeper] in sleeper.now }
    }

    static func settings() throws -> TaskRepositorySettings {
        let build = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        return TaskRepositorySettings(build: build, childChecks: ["build / build"])
    }

    /// `withoutSettings` なら、repo.json に build が無いリポジトリにする
    func environment(_ runner: FakeTaskRunner, withoutSettings: Bool = false) throws -> TaskJobEnvironment {
        let settings = withoutSettings ? nil : try Self.settings()
        return TaskJobEnvironment(
            context: context,
            git: git,
            pullRequests: { [pulls] _ in pulls },
            settings: { _ throws(CommanderError) in settings },
            runner: { target in
                runner.record(target)
                return runner
            },
            slots: BuildSlots(count: 2),
            reviewer: ClaudeClient(setup: QuestionJobsTests.setup, runner: reviewer),
            sleeper: sleeper
        )
    }

    /// running の epic と、t1 を終えたゴールを置く
    func prepare(stage: EpicStage = .running) async throws {
        let time = Timestamp(Self.start)
        let epic = EpicFile(id: Self.epic, repo: Self.repo, title: "ランキング", stage: stage, mac: Self.mac, createdAt: time, updatedAt: time)
        var goal = TaskJobsTests.goal()
        goal.tasks[0].state = .done
        goal.tasks[1].state = .running
        try await files.create(epic, at: StatePath.epic(Self.repo, Self.epic), message: "epic")
        try await files.create(goal, at: StatePath.goal(Self.repo, Self.epic), message: "goal")
    }

    var files: StateFileStore { StateFileStore(store: store) }

    /// 子ブランチから作業ブランチへの開いた子 PR #41
    static func openPull(head: String) -> PullRequest {
        PullRequest(number: 41, state: .open, merged: false, head: (branches.task, head), baseRef: branches.epic)
    }

    func job(_ kind: JobKind, _ id: String, task: String = "t2", input: [String: JSONValue]? = nil) -> JobFile {
        let time = Timestamp(Self.start)
        return JobFile(
            id: ULID(rawValue: "01JCJ0B00000000000000000" + id)!,
            kind: kind,
            repo: Self.repo,
            epic: Self.epic,
            task: task,
            assignedMac: Self.mac,
            needs: .init(claude: true, build: kind != .reviewTask),
            state: .assigned,
            input: input,
            createdAt: time,
            updatedAt: time
        )
    }

    /// 終えた試行を置く（前のジョブの結果）
    func record(
        _ job: JobFile,
        outputs: AttemptFile.Outputs? = nil,
        claude: AttemptFile.Claude? = nil,
        endedAt offset: TimeInterval = 0
    ) async throws {
        try await files.create(job, at: StatePath.job(Self.repo, epic: Self.epic, job: job.id), message: "job")
        let time = Timestamp(Self.start.addingTimeInterval(offset))
        let attempt = AttemptFile(
            job: job.id,
            number: 1,
            mac: Self.mac,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: outputs,
            claude: claude
        )
        try await files.create(attempt, at: StatePath.attempt(Self.repo, epic: Self.epic, job: job.id, number: 1), message: "attempt")
    }
}
