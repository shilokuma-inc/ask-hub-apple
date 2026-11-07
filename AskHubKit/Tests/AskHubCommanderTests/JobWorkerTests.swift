import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// ジョブを試行として実行し、結果を試行に書く
extension ClaudeJobRunnerTests {
    func worker(_ store: InMemoryStateStore, claude: any CommandRunning, workspace failure: WorkspaceError? = nil) -> JobWorker {
        JobWorker(
            runner: runner(store, claude: claude, workspace: failure),
            recorder: AttemptRecorder(files: StateFileStore(store: store), mac: Self.commander) { Self.now },
            now: { Self.now }
        )
    }

    @Test func workerRecordsSucceededAttemptWithClaudeSession() async throws {
        let given = try await requested()
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        let attempt = try #require(try await worker(given.store, claude: claude).perform(given.job))
        #expect(attempt.number == 1)
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.claude?.model == "claude-opus-5-5")
        #expect(attempt.claude?.session == "s-1")
        let path = StatePath.attempt(Self.repo, epic: given.epic.id, job: given.job.id, number: 1)
        #expect(try await read(AttemptFile.self, at: path, in: given.store) == attempt)
        // 同じ番号の試行がすでにあれば、引き受けない
        #expect(try await worker(given.store, claude: ScriptedRunner([])).perform(given.job) == nil)
    }

    @Test func workerRecordsFailureClassOfJob() async throws {
        let given = try await requested()
        let worker = worker(given.store, claude: ScriptedRunner([]), workspace: .unauthorized("401"))
        let attempt = try #require(try await worker.perform(given.job))
        #expect(attempt.outcome == .failed)
        #expect(attempt.failure?.failureClass == .authExpired)
        #expect(attempt.claude == nil)
    }

    @Test func discardedResultFinishesAsSuccess() async throws {
        let given = try await requested()
        var abandoned = given.epic
        abandoned.stage = .abandoned
        try await put(abandoned, at: StatePath.epic(Self.repo, abandoned.id), in: given.store)
        let attempt = try #require(try await worker(given.store, claude: ScriptedRunner([])).perform(given.job))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.failure == nil)
    }

    @Test func workerWritesOutputsAndThrownFailures() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        let outputs = AttemptFile.Outputs(pullRequest: 41, commit: String(repeating: "a", count: 40))
        let worker = JobWorker(runner: StubJob { _ in JobResult(outputs: outputs) }, recorder: recorder)
        let attempt = try #require(try await worker.perform(given.job))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.outputs == outputs)
        // やり直せば済む失敗（状態リポジトリに書けないなど）は、試行の失敗として書く
        var next = given.job
        next.attempts = 1
        let failing = JobWorker(runner: StubJob { _ throws(CommanderError) in throw .store(.serverError(status: 502)) }, recorder: recorder)
        let failed = try #require(try await failing.perform(next))
        #expect(failed.number == 2)
        #expect(failed.failure?.failureClass == .githubOutage)
    }

    @Test func storeFailuresBecomeAttemptFailures() {
        let now = Self.now
        let limited = CommanderError.store(.rateLimited(retryAfter: .seconds(60))).attemptFailure(now: now)
        #expect(limited.failureClass == .githubOutage)
        #expect(limited.retryAt == Timestamp(now.addingTimeInterval(60)))
        #expect(CommanderError.files(.store(.unauthorized)).attemptFailure(now: now).failureClass == .authExpired)
        #expect(CommanderError.files(.store(.serverError(status: 502))).attemptFailure(now: now).failureClass == .githubOutage)
        #expect(CommanderError.files(.tooManyConflicts).attemptFailure(now: now).failureClass == .githubOutage)
        #expect(CommanderError.changedWhileProcessing("repos/o/r/x.json").attemptFailure(now: now).failureClass == .flaky)
        #expect(CommanderError.files(.notFound).attemptFailure(now: now).failureClass == .unexpected)
        // 司令塔を止めて取り消されたのは、失敗に数えず続きから試す
        #expect(CommanderError.store(.cancelled).attemptFailure(now: now).failureClass == .macOffline)
    }
}

/// 決まった結果を返すジョブ
struct StubJob: JobRunning {
    let result: @Sendable (JobFile) throws(CommanderError) -> JobResult

    init(_ result: @escaping @Sendable (JobFile) throws(CommanderError) -> JobResult) {
        self.result = result
    }

    func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try result(job)
    }
}
