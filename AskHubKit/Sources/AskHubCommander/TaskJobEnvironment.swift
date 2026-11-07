import AskHubBuild
import AskHubClaude
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// タスクのジョブで使う、リポジトリの設定（`repo.json` の `build`。`docs/renewal/protocol.md`）
public struct TaskRepositorySettings: Equatable, Sendable {
    /// 作業ブランチの元で、最終 PR の向き先
    public var baseBranch: String
    public var build: BuildSettings
    /// 子 PR で待つチェックの名前。nil ならすべて
    public var childChecks: Set<String>?
    /// 最終 PR で待つチェックの名前。nil ならすべて
    public var finalChecks: Set<String>?
    /// 指摘を Claude に渡してよいレビューの書き手（`coderabbitai[bot]` など）
    public var trustedReviewers: [String]

    public init(
        baseBranch: String = "develop",
        build: BuildSettings,
        childChecks: Set<String>? = nil,
        finalChecks: Set<String>? = nil,
        trustedReviewers: [String] = []
    ) {
        self.baseBranch = baseBranch
        self.build = build
        self.childChecks = childChecks
        self.finalChecks = finalChecks
        self.trustedReviewers = trustedReviewers
    }
}

extension TaskRepositorySettings {
    /// `repo.json` の `build` から作る
    public init(_ build: RepositoryFile.Build) {
        self.init(
            baseBranch: build.baseBranch,
            build: build.xcode,
            childChecks: Set(build.childChecks),
            finalChecks: Set(build.finalChecks),
            trustedReviewers: build.trustedReviewers
        )
    }

    /// リポジトリのビルドの設定を、状態リポジトリの `repo.json` の `build` から読む閉包（`TaskJobEnvironment.settings`）。
    /// `repo.json` か `build` が無ければ nil（タスクのジョブは理由を付けて人へ渡る）
    public static func reader(context: CommanderContext) -> @Sendable (RepositoryFullName) async throws(CommanderError) -> Self? {
        { repo throws(CommanderError) in
            try await context.read(RepositoryFile.self, at: StatePath.repository(repo))?.build.map(Self.init)
        }
    }
}

/// Claude にタスクを進めさせるもの。本物は `TaskRunner`
public protocol TaskRunning: Sendable {
    func run<Job: TaskJob>(_ job: Job, in workspace: TaskWorkspace) async -> TaskReply
}

extension TaskRunner: TaskRunning {}

/// ビルドとテストを流す、epic の作業場所とビルドの枠
public struct BuildTarget: Equatable, Sendable {
    public var epic: ULID
    public var directory: URL
    public var settings: BuildSettings
    public var slot: Int

    public init(epic: ULID, directory: URL, settings: BuildSettings, slot: Int) {
        self.epic = epic
        self.directory = directory
        self.settings = settings
        self.slot = slot
    }
}

/// タスクのジョブ（`implementTask`・`reviewTask`・`fixTask`）が使うもの。常時オンの Mac の司令塔とワーカーで同じものを組み立てる
public struct TaskJobEnvironment: Sendable {
    public var context: CommanderContext
    public var git: any TaskGit
    /// リポジトリの PR の操作（リポジトリの持ち主の GitHub のトークンで呼ぶ）
    public var pullRequests: @Sendable (RepositoryFullName) -> any PullRequestOperations
    /// リポジトリの設定。`repo.json` に `build` が無ければ nil（`build` の無いリポジトリでは開始を断るので、普通は無い）
    public var settings: @Sendable (RepositoryFullName) async throws(CommanderError) -> TaskRepositorySettings?
    /// Claude に実装させるもの。ビルドとテストは、渡した epic の作業場所と枠で流す
    public var runner: @Sendable (BuildTarget) -> any TaskRunning
    /// この Mac のビルドの枠
    public var slots: BuildSlots
    /// 子 PR のレビュー役の Claude を呼ぶもの
    public var reviewer: ClaudeClient
    public var sleeper: any Sleeper
    /// epic の作業場所を、1 つのジョブだけが使うようにする
    public var locks: EpicLocks

    public init(
        context: CommanderContext,
        git: any TaskGit,
        pullRequests: @escaping @Sendable (RepositoryFullName) -> any PullRequestOperations,
        settings: @escaping @Sendable (RepositoryFullName) async throws(CommanderError) -> TaskRepositorySettings?,
        runner: @escaping @Sendable (BuildTarget) -> any TaskRunning,
        slots: BuildSlots,
        reviewer: ClaudeClient,
        sleeper: any Sleeper = TaskSleeper(),
        locks: EpicLocks = EpicLocks()
    ) {
        self.context = context
        self.git = git
        self.pullRequests = pullRequests
        self.settings = settings
        self.runner = runner
        self.slots = slots
        self.reviewer = reviewer
        self.sleeper = sleeper
        self.locks = locks
    }
}

/// epic の作業場所（同じ worktree）を、取り出してから commit・レビューを終えるまで 1 つのジョブだけが使うようにする。
///
/// タスクは 1 つずつ進めるが、時間切れとみなされた試行のやり直しが元の試行と重なると、後の取り出しが先の変更を捨ててしまう。
/// 作業場所は役割（司令塔・ワーカー）ごとのフォルダにあり、同じ役割は Mac に 1 つだけ動かすので、プロセスの中で排他すれば足りる
public actor EpicLocks {
    private var held: Set<ULID> = []
    private var waiters: [ULID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    func acquire(_ epic: ULID) async {
        guard held.contains(epic) else {
            held.insert(epic)
            return
        }
        await withCheckedContinuation { waiters[epic, default: []].append($0) }
    }

    func release(_ epic: ULID) {
        if var queue = waiters[epic], !queue.isEmpty {
            queue.removeFirst().resume()
            waiters[epic] = queue.isEmpty ? nil : queue
        } else {
            held.remove(epic)
        }
    }

    /// 待っているジョブの数（テストで使う）
    func waiting(for epic: ULID) -> Int {
        waiters[epic]?.count ?? 0
    }
}

/// タスクのジョブを途中で終える理由
enum TaskJobExit: Error {
    /// 試行に書く結果で終える（失敗・何もせずに終える）
    case finish(JobResult)
    /// 状態リポジトリを読めない（やり直せば済むので、試行の失敗として投げる）
    case state(CommanderError)

    static func fail(_ failureClass: FailureClass, _ message: String, keeping partial: JobResult = JobResult()) -> Self {
        let failure = AttemptFailure(failureClass: failureClass, message: message)
        return .finish(JobResult(failure: failure, outputs: partial.outputs, claude: partial.claude))
    }
}

/// 1 つのタスクのジョブで読むもの
struct TaskTarget: Sendable {
    var epic: EpicFile
    var goal: GoalFile
    var task: GoalFile.Task
    var settings: TaskRepositorySettings
    var branches: TaskBranches
}

extension TaskJobEnvironment {
    /// `kind` のジョブとして流す。途中で終えた理由は試行の結果にし、状態リポジトリを読めないときだけ投げる
    func perform(
        _ job: JobFile,
        as kind: JobKind,
        _ body: (TaskTarget) async throws(TaskJobExit) -> JobResult
    ) async throws(CommanderError) -> JobResult {
        guard job.kind == kind else {
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) は \(kind.rawValue) として扱えない"))
        }
        do {
            return try await body(try await target(of: job))
        } catch {
            switch error {
            case let .finish(result): return result
            case let .state(error): throw error
            }
        }
    }

    /// ジョブの epic・ゴール・タスク・リポジトリの設定を読む。実装していない epic（やめた・終えた）なら、何もせずに終える
    private func target(of job: JobFile) async throws(TaskJobExit) -> TaskTarget {
        guard let id = job.task else { throw .fail(.unexpected, "ジョブにタスクが無い") }
        guard let epic = try await read(EpicFile.self, at: StatePath.epic(job.repo, job.epic)) else {
            throw .fail(.unexpected, "epic \(job.epic) が無い")
        }
        // 開始した後にやめた epic は進めない（ジョブとしては成功で終える）
        guard epic.stage == .running else { throw .finish(JobResult()) }
        guard let goal = try await read(GoalFile.self, at: StatePath.goal(job.repo, job.epic)),
              let task = goal.tasks.first(where: { $0.id == id }) else {
            throw .fail(.unexpected, "ゴールにタスク \(id) が無い")
        }
        let settings: TaskRepositorySettings?
        do {
            settings = try await self.settings(job.repo)
        } catch {
            throw .state(error)
        }
        guard let settings else { throw .fail(.unexpected, "\(job.repo) の repo.json に build（ビルドの設定）が無い") }
        let branches = TaskBranches(base: settings.baseBranch, epic: epic, task: id)
        return TaskTarget(epic: epic, goal: goal, task: task, settings: settings, branches: branches)
    }

    /// epic の作業場所を借りて `body` を流す
    func exclusively<Value>(_ epic: ULID, _ body: () async throws(TaskJobExit) -> Value) async throws(TaskJobExit) -> Value {
        await locks.acquire(epic)
        do {
            let value = try await body()
            await locks.release(epic)
            return value
        } catch {
            await locks.release(epic)
            throw error
        }
    }

    func read<File: StateFile>(_ type: File.Type, at path: String) async throws(TaskJobExit) -> File? {
        do {
            return try await context.read(type, at: path)
        } catch {
            throw .state(error)
        }
    }

    /// GitHub の PR の操作。失敗したら、`partial`（それまでの Claude の記録など）を付けて試行の失敗として終える
    func github<Value>(
        _ what: String,
        keeping partial: JobResult = JobResult(),
        _ body: () async throws(PullRequestError) -> Value
    ) async throws(TaskJobExit) -> Value {
        do {
            return try await body()
        } catch {
            let failure = error.attemptFailure(doing: what, now: context.now())
            throw .finish(JobResult(failure: failure, outputs: partial.outputs, claude: partial.claude))
        }
    }

    /// epic の作業場所の git の操作。失敗したら、`partial` を付けて試行の失敗として終える
    func workspace<Value>(
        keeping partial: JobResult = JobResult(),
        _ body: () async throws(WorkspaceError) -> Value
    ) async throws(TaskJobExit) -> Value {
        do {
            return try await body()
        } catch {
            throw .finish(JobResult(failure: error.attemptFailure, outputs: partial.outputs, claude: partial.claude))
        }
    }

    /// Claude にタスクを進めさせる。ビルドとテストは、この Mac の枠を 1 つ借りて流す
    func run<Job: TaskJob>(_ job: Job, in checkout: CheckedOutTask, target: TaskTarget) async -> TaskReply {
        let workspace = TaskWorkspace(repository: checkout.repo, facts: checkout.facts, directory: checkout.directory)
        return await slots.withSlot { slot in
            let build = BuildTarget(epic: target.epic.id, directory: checkout.directory, settings: target.settings.build, slot: slot)
            return await runner(build).run(job, in: workspace)
        }
    }
}

extension TaskReply {
    /// `done` なら報告と記録を返す。人に聞きたいことがある・進められない・失敗したときは、理由を付けた試行の失敗として終える（人へ渡る）
    func done() throws(TaskJobExit) -> (report: TaskReport, run: TaskRun) {
        switch self {
        case let .reported(reported, run):
            // 報告は子 PR・コミット・状態リポジトリに書くので、トークンらしい文字列を伏せてから使う（Claude にトークンは渡していないが、念のため）
            let report = reported.redacted
            let partial = JobResult(outputs: AttemptFile.Outputs(report: report.outputReport), claude: run.session?.attemptRecord)
            switch report.outcome {
            case .done:
                return (report, run)
            case .needsQuestion:
                let title = report.question?.title ?? report.summary
                throw .fail(.unexpected, "Claude が、人に決めてほしいことがあると報告した（\(UntrustedText.head(title, limit: 300))）", keeping: partial)
            case .blocked, .needsBuild:
                throw .fail(.unexpected, "Claude が、進められないと報告した（\(UntrustedText.head(report.summary, limit: 300))）", keeping: partial)
            }
        case let .failed(failure, run):
            var failure = failure
            // ビルドとテストの往復を使い切った（`TaskRunner` はビルドとテストの失敗として返す）。今は Claude に直させずに人へ渡す
            if [.buildFailed, .testFailed].contains(failure.failureClass) { failure.failureClass = .unexpected }
            // 試行に書く前に、説明とログの抜粋のトークンらしい文字列を伏せる
            failure.message = Redaction.redact(failure.message, secrets: [])
            failure.logExcerpt = failure.logExcerpt.flatMap { Redaction.excerpt(of: $0, secrets: []) }
            throw .finish(JobResult(failure: failure, claude: run.session?.attemptRecord))
        }
    }
}

extension TaskReport {
    /// 人が読む欄のトークンらしい文字列を伏せたもの
    var redacted: Self {
        let hide = { (text: String) in Redaction.redact(text, secrets: []) }
        var report = self
        report.summary = hide(summary)
        report.decisions = decisions.map { Decision(what: hide($0.what), why: hide($0.why), alternatives: $0.alternatives.map(hide)) }
        report.learnings = learnings.map(hide)
        report.question = question.map { question in
            let options = question.options.map { QuestionsFile.Option(label: hide($0.label), effect: hide($0.effect)) }
            return Question(
                title: hide(question.title),
                why: hide(question.why),
                options: options,
                recommended: hide(question.recommended),
                reason: hide(question.reason)
            )
        }
        return report
    }

    /// 試行の `outputs.report` に書く形
    var outputReport: TaskOutputReport {
        TaskOutputReport(
            summary: summary,
            decisions: decisions.map { TaskOutputReport.Decision(what: $0.what, why: $0.why, alternatives: $0.alternatives) },
            learnings: learnings,
            question: question.map {
                TaskOutputReport.Question(title: $0.title, why: $0.why, options: $0.options, recommended: $0.recommended, reason: $0.reason)
            }
        )
    }
}

extension PullRequestError {
    /// 試行の失敗の区分（`docs/renewal/architecture.md` の「失敗の区分と既定の扱い」）
    func attemptFailure(doing what: String, now: Date) -> AttemptFailure {
        switch self {
        case .unauthorized, .tokenUnavailable:
            AttemptFailure(failureClass: .authExpired, message: "GitHub のトークンが使えないので、\(what)ことができない")
        case .forbidden:
            AttemptFailure(failureClass: .authExpired, message: "GitHub のトークンに権限が無いので、\(what)ことができない（\(self)）")
        case let .rateLimited(wait):
            AttemptFailure(
                failureClass: .githubOutage,
                message: "GitHub の上限に達したので、\(what)ことができない",
                retryAt: Timestamp(now.addingTimeInterval(TimeInterval(wait.components.seconds)))
            )
        case .serverError, .transport:
            AttemptFailure(failureClass: .githubOutage, message: "GitHub に届かないので、\(what)ことができない（\(self)）")
        case .cancelled:
            AttemptFailure(failureClass: .macOffline, message: "ワーカーを止めたので、\(what)ことを中断した")
        default:
            AttemptFailure(failureClass: .unexpected, message: "\(what)ことができない（\(self)）")
        }
    }
}
