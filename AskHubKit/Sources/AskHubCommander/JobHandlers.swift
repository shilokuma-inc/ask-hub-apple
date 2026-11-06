import AskHubProtocol
import Foundation

/// やり直しの人の意図（`retry`）を受け付け、人に渡したジョブを `assigned` に戻す（`docs/renewal/architecture.md` の「失敗の扱い」）。
///
/// 試行の番号（`targetVersion`）が、人が見たときのままのときだけ受け付ける。次の試行は担当の Mac がそのまま引き受ける。
/// 試行の失敗の数え方は変えないので、続けて同じ失敗をすれば、また人に渡る
public struct RetryJobHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let retry: RetryJobIntent
        do {
            retry = try RetryJobIntent(envelope: envelope)
        } catch {
            return .reject("やり直しの形が違う（\(error.detail)）")
        }
        // 前の周で戻した（やり直し）か、人に渡した後に元の試行が成功した
        switch try await WaitingJob.read(retry.target, done: [.assigned, .running, .succeeded], in: context) {
        case let .decided(decision):
            return decision
        case let .waiting(job, _):
            let now = context.timestamp
            try await WaitingJob.write(job, message: "ジョブ \(job.kind.rawValue) をやり直す", in: context) {
                $0.state = .assigned
                $0.nextRunAt = nil
                $0.updatedAt = now
            }
            return .accept
        }
    }
}

/// 人の対応を待っている（`waitingHuman` の）ジョブを対象にする意図の、対象の読み方と書き方
enum WaitingJob {
    case waiting(JobFile, EpicFile)
    /// 受け付けられない・前の周で済んでいる
    case decided(IntentDecision)

    /// 対象のジョブと epic を読む。ジョブが `done` の状態なら、前の周で済んだものとして受け付ける
    static func read(_ target: JobTarget, done: Set<JobState>, in context: CommanderContext) async throws(CommanderError) -> Self {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)) else {
            return .decided(.reject("epic が無い"))
        }
        guard ![.merged, .abandoned].contains(epic.stage) else { return .decided(.reject("epic はもう終わっている（\(epic.stage.rawValue)）")) }
        guard let job = try await context.read(JobFile.self, at: StatePath.job(target.repo, epic: target.epic, job: target.job)) else {
            return .decided(.reject("ジョブが無い"))
        }
        guard job.attempts == target.attempt else { return .decided(.reject("試行の番号が今のジョブと違う（今は \(job.attempts)）")) }
        if done.contains(job.state) { return .decided(.accept) }
        guard job.state == .waitingHuman else { return .decided(.reject("ジョブは人の対応を待っていない（\(job.state.rawValue)）")) }
        return .waiting(job, epic)
    }

    /// 読んだときのままのジョブだけを書き換える。読んだ後に書き換わっていれば、次の周で読み直して決める
    static func write(
        _ job: JobFile,
        message: String,
        in context: CommanderContext,
        change: @escaping @Sendable (inout JobFile) -> Void
    ) async throws(CommanderError) {
        let path = StatePath.job(job.repo, epic: job.epic, job: job.id)
        var written = false
        do {
            try await context.files.update(JobFile.self, at: path, message: message) {
                guard $0 == job else { return false }
                change(&$0)
                written = true
                return true
            }
        } catch {
            throw .files(error)
        }
        guard written else { throw .changedWhileProcessing(path) }
    }
}
