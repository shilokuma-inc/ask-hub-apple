import AskHubProtocol
import Foundation

/// 作業場所の用意（`prepareWorkspace`）を 1 回実行する（`docs/renewal/flows.md` の「作業ブランチと子 PR」）。
/// 開始のときに人が選んだ Mac で動く（ワーカーと、常時オンの Mac の司令塔の両方）。
///
/// epic の作業場所に作業ブランチ `askhub/<epic の id>` を取り出し、無ければ base の最新から作って push する。
/// 作業ブランチの名前と先頭のコミットは試行の `outputs` に書く（`epic.json` は司令塔だけが書く）
public struct PrepareWorkspaceRunner: JobRunning {
    public var context: CommanderContext
    public var workspace: any EpicWorkspace
    /// 作業ブランチを作る元のブランチの既定。`repo.json` の `build.baseBranch` があれば、そちらを使う
    public var base: String

    public init(context: CommanderContext, workspace: any EpicWorkspace, base: String = "develop") {
        self.context = context
        self.workspace = workspace
        self.base = base
    }

    /// epic の作業ブランチの名前
    public static func branch(of epic: ULID) -> String {
        "askhub/\(epic.rawValue)"
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        guard job.kind == .prepareWorkspace else {
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) は作業場所の用意として扱えない"))
        }
        // 開始した後にやめた epic は用意しない（ジョブとしては成功で終える）
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(job.repo, job.epic)), epic.stage == .running else {
            return JobResult()
        }
        let repository = try await context.read(RepositoryFile.self, at: StatePath.repository(job.repo))
        let base = repository?.build?.baseBranch ?? base
        do {
            let branch = epic.branch ?? Self.branch(of: epic.id)
            let prepared = try await workspace.prepareEpic(job.repo, epic: epic.id, branch: branch, base: base)
            return JobResult(outputs: AttemptFile.Outputs(commit: prepared.head, branch: prepared.branch))
        } catch {
            return JobResult(failure: error.attemptFailure)
        }
    }
}

/// ジョブの種類ごとに、実行するものを選ぶ
public struct JobDispatcher: JobRunning {
    public var runners: [JobKind: any JobRunning]

    public init(_ runners: [JobKind: any JobRunning]) {
        self.runners = runners
    }

    /// この Mac が引き受けるジョブの種類
    public var kinds: Set<JobKind> { Set(runners.keys) }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        guard let runner = runners[job.kind] else {
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: "この Mac では \(job.kind.rawValue) を扱えない"))
        }
        return try await runner.execute(job)
    }
}
