import AskHubBuild
import AskHubClaude
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR の前の検証と、epic の片付けで使う、この Mac のビルドの道具。本物は `MachineFinalBuilds`
public protocol FinalBuilding: Sendable {
    /// epic の作業場所で検証を流す。失敗も結果として返し、投げるのは取り消されたときだけ
    func run(_ kind: BuildKind, on target: BuildTarget) async throws(CancellationError) -> BuildRun
    /// epic の DerivedData と結果のバンドルを消す
    func removeProducts(of epic: ULID) throws(BuildDirectoryError)
    /// 枠 `slot` の Simulator（ワーカーが作ったもの）を消去する（入れたアプリとデータ）。消去できなかったものの説明を返す
    func eraseSimulators(slot: Int) async -> [String]
}

/// `AskHubBuild` の `EpicBuilder`・`BuildDirectories`・`SimulatorPool` で流し、片付ける
public struct MachineFinalBuilds: FinalBuilding {
    public var machine: BuildMachine

    public init(machine: BuildMachine) {
        self.machine = machine
    }

    public func run(_ kind: BuildKind, on target: BuildTarget) async throws(CancellationError) -> BuildRun {
        let builder = EpicBuilder(
            machine: machine, settings: target.settings, epic: target.epic, sourceDirectory: target.directory, slot: target.slot
        )
        return try await builder.run(kind)
    }

    public func removeProducts(of epic: ULID) throws(BuildDirectoryError) {
        try machine.runner.directories.remove(epic)
    }

    public func eraseSimulators(slot: Int) async -> [String] {
        let prefix = "\(SimulatorPool.namePrefix)\(slot)-"
        let simulators: [Simulator]
        do {
            simulators = try await machine.pool.workerSimulators()
        } catch {
            return [error.message]
        }
        var problems: [String] = []
        for simulator in simulators where simulator.name.hasPrefix(prefix) {
            do {
                try await machine.pool.erase(simulator)
            } catch {
                problems.append(error.message)
            }
        }
        return problems
    }
}

/// 最終 PR のレビューの待ち方
public struct FinalReviewTiming: Equatable, Sendable {
    /// 待つチェック（`build.finalChecks`）の待ち方
    public var checks: ReviewTiming
    /// 信用するレビューの書き手（CodeRabbit）のレビューを読み直す間隔
    public var reviewerPoll: Duration
    /// レビューが始まる（CodeRabbit の check run・commit status が出てくる）のを待つ上限。超えたら、待たずに今ある指摘で進める
    public var reviewerStartLimit: Duration
    /// レビューが終わるのを待つ上限。超えたら、待たずに今ある指摘で進める
    public var reviewerLimit: Duration

    public init(
        checks: ReviewTiming = ReviewTiming(),
        reviewerPoll: Duration = .seconds(60),
        reviewerStartLimit: Duration = .seconds(15 * 60),
        reviewerLimit: Duration = .seconds(60 * 60)
    ) {
        self.checks = checks
        self.reviewerPoll = reviewerPoll
        self.reviewerStartLimit = reviewerStartLimit
        self.reviewerLimit = reviewerLimit
    }
}

/// 最終 PR の段取りのジョブ（`verifyBeforeFinal`・`classifyDecisions`・`openFinalPullRequest`・`reviewFinalPullRequest`・
/// `fixFinalPullRequest`・`mergeFinalPullRequest`・`cleanUp`）が使うもの。常時オンの Mac の司令塔とワーカーで同じものを組み立てる
public struct FinalJobEnvironment: Sendable {
    /// タスクのジョブと共有するもの（状態リポジトリ・PR の操作・リポジトリの設定・Claude・ビルドの枠・epic の作業場所の排他）
    public var tasks: TaskJobEnvironment
    public var git: any FinalGit
    public var builds: any FinalBuilding
    /// 人の意図の署名を確かめるもの（最終 PR への指示・判断のカードの答え・マージの承認を読む）
    public var verifier: @Sendable () async throws(CommanderError) -> IntentVerifier
    public var timing: FinalReviewTiming

    public init(
        tasks: TaskJobEnvironment,
        git: any FinalGit,
        builds: any FinalBuilding,
        verifier: @escaping @Sendable () async throws(CommanderError) -> IntentVerifier,
        timing: FinalReviewTiming = FinalReviewTiming()
    ) {
        self.tasks = tasks
        self.git = git
        self.builds = builds
        self.verifier = verifier
        self.timing = timing
    }

    var context: CommanderContext { tasks.context }
}

/// 1 つの最終 PR の段取りのジョブで読むもの
struct FinalTarget: Sendable {
    var epic: EpicFile
    var goal: GoalFile
    var settings: TaskRepositorySettings
    var branches: FinalBranches
}

extension FinalJobEnvironment {
    /// 最終 PR の段取りを進める epic の段階。ほか（やめた・終えた）の epic では何もしない
    static let activeStages: Set<EpicStage> = [.running, .finalizing, .reviewing]

    /// `kind` のジョブとして流す。途中で終えた理由は試行の結果にし、状態リポジトリを読めないときだけ投げる
    func perform(
        _ job: JobFile,
        as kind: JobKind,
        _ body: (FinalTarget) async throws(TaskJobExit) -> JobResult
    ) async throws(CommanderError) -> JobResult {
        guard job.kind == kind else {
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) は \(kind.rawValue) として扱えない"))
        }
        do {
            guard let target = try await target(of: job) else { return JobResult() }
            return try await body(target)
        } catch {
            switch error {
            case let .finish(result): return result
            case let .state(error): throw error
            }
        }
    }

    /// ジョブの epic・ゴール・リポジトリの設定を読む。最終 PR の段取りを進めていない epic（やめた・終えた）なら nil
    private func target(of job: JobFile) async throws(TaskJobExit) -> FinalTarget? {
        guard let epic = try await tasks.read(EpicFile.self, at: StatePath.epic(job.repo, job.epic)) else {
            throw .fail(.unexpected, "epic \(job.epic) が無い")
        }
        guard Self.activeStages.contains(epic.stage) else { return nil }
        guard let goal = try await tasks.read(GoalFile.self, at: StatePath.goal(job.repo, job.epic)) else {
            throw .fail(.unexpected, "epic \(job.epic) のゴールが無い")
        }
        let settings: TaskRepositorySettings?
        do {
            settings = try await tasks.settings(job.repo)
        } catch {
            throw .state(error)
        }
        guard let settings else { throw .fail(.unexpected, "\(job.repo) の repo.json に build（ビルドの設定）が無い") }
        return FinalTarget(epic: epic, goal: goal, settings: settings, branches: FinalBranches(base: settings.baseBranch, epic: epic))
    }

    /// epic の作業場所を借りて `body` を流す（タスクのジョブと同じ排他）
    func exclusively<Value>(_ epic: ULID, _ body: () async throws(TaskJobExit) -> Value) async throws(TaskJobExit) -> Value {
        try await tasks.exclusively(epic, body)
    }

    /// 最終 PR が、作業ブランチから base に向いているか（入力の PR の番号の取り違えで、ほかの PR を扱わない）
    static func checkDirection(_ pull: PullRequest, branches: FinalBranches, keeping partial: JobResult = JobResult()) throws(TaskJobExit) {
        guard pull.headRef == branches.epic, pull.baseRef == branches.base else {
            let expected = "\(branches.epic) → \(branches.base)"
            let message = "最終 PR #\(pull.number) の向き（\(pull.headRef) → \(pull.baseRef)）が、作業ブランチから base（\(expected)）への向きでない"
            throw .fail(.unexpected, message, keeping: partial)
        }
    }

    /// ジョブの元になった人の意図。署名を確かめ、無い・確かめられないときは nil
    func origin(of job: JobFile) async throws(TaskJobExit) -> IntentEnvelope? {
        do {
            return try await context.envelope(of: job.origin, verifier: try await verifier())
        } catch {
            throw .state(error)
        }
    }

    /// `head`（nil なら作業ブランチのリモートの先頭）をジョブのフォルダに取り出して `body` に読ませ、終わったらフォルダを消す
    func withFinalCheckout<Value>(
        _ job: JobFile,
        target: FinalTarget,
        head: String?,
        _ body: (FinalReviewCheckout) async throws(TaskJobExit) -> Value
    ) async throws(TaskJobExit) -> Value {
        let git = git
        do {
            let checkout = try await tasks.workspace { () throws(WorkspaceError) in
                try await git.checkOutFinal(job.repo, job: job.id, branches: target.branches, head: head)
            }
            let value = try await body(checkout)
            await git.release(job.id)
            return value
        } catch {
            await git.release(job.id)
            throw error
        }
    }

    /// 読むだけのレビュー役の Claude に聞く。失敗したら、途中までの Claude の記録を付けて試行の失敗として終える
    func ask<Output: Decodable & Sendable>(
        _ request: ClaudeRequest,
        as type: Output.Type,
        check: @Sendable (Output) -> [String]
    ) async throws(TaskJobExit) -> (result: Output, session: ClaudeSession) {
        switch await tasks.reviewer.ask(request, as: type, now: context.now, check: check) {
        case let .answered(result, session):
            return (result, session)
        case let .failed(failure, session):
            throw .finish(JobResult(failure: failure, claude: session?.attemptRecord))
        }
    }

    /// Claude に直させる。ビルドとテストは、この Mac の枠を 1 つ借りて流す
    func run<Job: TaskJob>(_ job: Job, in checkout: CheckedOutEpic, target: FinalTarget) async -> TaskReply {
        let workspace = TaskWorkspace(repository: checkout.repo, facts: checkout.facts, directory: checkout.directory)
        let tasks = tasks
        return await tasks.slots.withSlot { slot in
            let build = BuildTarget(epic: target.epic.id, directory: checkout.directory, settings: target.settings.build, slot: slot)
            return await tasks.runner(build).run(job, in: workspace)
        }
    }
}
