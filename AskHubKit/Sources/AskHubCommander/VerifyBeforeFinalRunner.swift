import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation

/// 最終 PR の前の検証（`verifyBeforeFinal`）を 1 回実行する（`docs/renewal/flows.md` の「出す前に」）。epic の Mac で動く。
///
/// 作業ブランチを epic の作業場所に取り出し、最終 PR で流すのと同じ検証（`build.xcode.testFull`。子 PR では流さない UI テストを含む）を
/// `EpicBuilder` で通す。落ちたら `buildFailed`・`testFailed` の失敗にする（ログの抜粋は伏せてから書く）
public struct VerifyBeforeFinalRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .verifyBeforeFinal) { target throws(TaskJobExit) in
            try await environment.exclusively(job.epic) { () throws(TaskJobExit) in try await verify(job, target) }
        }
    }

    private func verify(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        let environment = environment
        let checkout = try await environment.tasks.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutEpic(job.repo, epic: job.epic, branches: target.branches)
        }
        // 検証した作業ブランチの先頭（司令塔は、これが最終 PR の head と同じかで、検証し直すかを決められる）
        let outputs = AttemptFile.Outputs(commit: checkout.head, branch: target.branches.epic)
        let run: BuildRun? = await environment.tasks.slots.withSlot { slot in
            let build = BuildTarget(epic: target.epic.id, directory: checkout.directory, settings: target.settings.build, slot: slot)
            return try? await environment.builds.run(.testFull, on: build)
        }
        guard let run else {
            throw .fail(.macOffline, "ワーカーを止めたので、最終 PR の前の検証を中断した", keeping: JobResult(outputs: outputs))
        }
        guard var failure = run.attemptFailure else { return JobResult(outputs: outputs) }
        failure.message = "最終 PR の前の検証（testFull）が通らない: " + Redaction.redact(failure.message, secrets: [])
        failure.logExcerpt = failure.logExcerpt.flatMap { Redaction.excerpt(of: $0, secrets: []) }
        return JobResult(failure: failure, outputs: outputs)
    }
}
