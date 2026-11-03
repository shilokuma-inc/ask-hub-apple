import AskHubProtocol
import AskHubStateStore
import Foundation

/// ワーカーが、自分の試行のファイルを書く（試行のファイルは、実行した Mac のワーカーだけが書く）
public struct AttemptRecorder: Sendable {
    public let files: StateFileStore
    public let mac: MacName
    private let now: @Sendable () -> Date

    public init(files: StateFileStore, mac: MacName, now: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files
        self.mac = mac
        self.now = now
    }

    /// ジョブを引き受ける。`attempts + 1` 番の試行を「実行中」で作る。
    /// すでにその番号の試行があれば `alreadyExists`（前に引き受けた・司令塔がまだ前の試行を読んでいない）で、引き受けない
    public func start(_ job: JobFile) async throws(StateFileStore.Failure) -> AttemptFile {
        guard job.assignedMac == mac, job.state == .assigned else { throw .invalidFile("自分宛ての assigned のジョブではない") }
        let time = Timestamp(now())
        let attempt = AttemptFile(job: job.id, number: job.attempts + 1, mac: mac, startedAt: time, heartbeatAt: time, outcome: .running)
        let message = "[attempt] \(job.kind.rawValue) \(job.id) #\(attempt.number) を始める"
        return try await files.create(attempt, at: path(job, attempt.number), message: message).file
    }

    /// 生きている印を書く（`JobTiming.heartbeatInterval` ごと）
    @discardableResult
    public func beat(_ attempt: AttemptFile, of job: JobFile) async throws(StateFileStore.Failure) -> AttemptFile {
        let time = Timestamp(now())
        return try await update(attempt, of: job, message: "[attempt] \(job.id) #\(attempt.number) 動いている") { file in
            file.heartbeatAt = max(file.heartbeatAt, time)
        }
    }

    /// 終わりを書く。`failure` は失敗のときだけ渡す
    @discardableResult
    public func finish(
        _ attempt: AttemptFile,
        of job: JobFile,
        failure: AttemptFailure?,
        outputs: AttemptFile.Outputs? = nil,
        claude: AttemptFile.Claude? = nil
    ) async throws(StateFileStore.Failure) -> AttemptFile {
        let time = Timestamp(now())
        let outcome: AttemptOutcome = failure == nil ? .succeeded : .failed
        return try await update(attempt, of: job, message: "[attempt] \(job.id) #\(attempt.number) \(outcome.rawValue)") { file in
            file.heartbeatAt = max(file.heartbeatAt, time)
            file.endedAt = max(time, file.startedAt)
            file.outcome = outcome
            file.failure = failure
            file.outputs = outputs ?? file.outputs
            file.claude = claude ?? file.claude
        }
    }

    private func update(
        _ attempt: AttemptFile,
        of job: JobFile,
        message: String,
        _ change: (inout AttemptFile) -> Void
    ) async throws(StateFileStore.Failure) -> AttemptFile {
        let mac = self.mac
        let current = try await files.update(AttemptFile.self, at: path(job, attempt.number), message: message) { file in
            // ほかの Mac の試行と、終わった試行は書き換えない
            guard file.mac == mac, file.outcome == .running else { return false }
            change(&file)
            return true
        }.file
        guard current.mac == mac else { throw .invalidFile("ほかの Mac（\(current.mac)）の試行は書き換えない") }
        return current
    }

    private func path(_ job: JobFile, _ number: Int) -> String {
        StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: number)
    }
}
