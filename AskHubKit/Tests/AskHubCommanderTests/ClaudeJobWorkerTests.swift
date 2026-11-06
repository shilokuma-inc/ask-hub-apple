import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// Claude のジョブを試行として実行し、結果を試行に書く
extension ClaudeJobRunnerTests {
    func worker(_ store: InMemoryStateStore, claude: any CommandRunning, workspace failure: WorkspaceError? = nil) -> ClaudeJobWorker {
        ClaudeJobWorker(
            runner: runner(store, claude: claude, workspace: failure),
            recorder: AttemptRecorder(files: StateFileStore(store: store), mac: Self.commander) { Self.now }
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
    }
}
