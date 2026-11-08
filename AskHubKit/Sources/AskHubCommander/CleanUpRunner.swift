import AskHubBuild
import AskHubProtocol
import Foundation

/// epic の片付け（`cleanUp`）を 1 回実行する（`docs/renewal/operations.md` の「容量」）。最終 PR のマージの後に、epic の Mac で動く。
///
/// - この Mac の epic の作業場所（worktree）と、手元の epic のブランチ（作業ブランチと子ブランチ）を消す
/// - epic の DerivedData と結果のバンドルを消す
/// - Simulator の枠は epic をまたいで使い回すので、消さずに中身（入れたアプリとデータ）を消去する。ほかのジョブがビルドに使っている枠は、
///   空くのを待ってから 1 つずつ借りて消去する
///
/// ほかの epic のものには触れない。リモートのブランチには触れない（作業ブランチはマージで消す）。
/// 消すのはこの Mac の写しだけ（push 済みのものから作り直せる）なので、epic の段階は見ない
public struct CleanUpRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        guard job.kind == .cleanUp else {
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) は cleanUp として扱えない"))
        }
        let epic = try await environment.context.read(EpicFile.self, at: StatePath.epic(job.repo, job.epic))
        let branch = epic?.branch ?? PrepareWorkspaceRunner.branch(of: job.epic)
        var problems = await removeWorkspace(job, branch: branch)
        let slots = environment.tasks.slots
        for slot in 0..<slots.count {
            await slots.acquire(slot: slot)
            problems += await environment.builds.eraseSimulators(slot: slot)
            await slots.release(slot)
        }
        guard problems.isEmpty else {
            let message = "epic の片付けで、消せないものがあった（\(problems.joined(separator: "・"))）"
            return JobResult(failure: AttemptFailure(failureClass: .unexpected, message: message))
        }
        return JobResult()
    }

    /// epic の作業場所・手元のブランチ・DerivedData を消す。ほかのジョブが作業場所を使っていれば、終わるのを待つ
    private func removeWorkspace(_ job: JobFile, branch: String) async -> [String] {
        let environment = environment
        await environment.tasks.locks.acquire(job.epic)
        var problems: [String] = []
        do {
            try await environment.git.removeEpic(job.repo, epic: job.epic, branch: branch)
        } catch {
            problems.append("epic の作業場所（\(error.detail)）")
        }
        do {
            try environment.builds.removeProducts(of: job.epic)
        } catch {
            problems.append("DerivedData（\(error.message)）")
        }
        await environment.tasks.locks.release(job.epic)
        return problems
    }
}

extension WorkspaceError {
    /// 説明（区分を除いたもの）
    var detail: String {
        switch self {
        case let .unavailable(detail), let .unauthorized(detail), let .failed(detail): detail
        }
    }
}
