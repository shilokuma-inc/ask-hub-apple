import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubEpics
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// 決まった書き込み（コミットのメッセージで見分ける）を、書き込みの予算を使い切ったとして決めた回数だけ断る置き場所
struct ExhaustingStore: StateStore {
    let inner: InMemoryStateStore
    let matching: @Sendable (String) -> Bool
    let wait: Duration
    private let refusals: OSAllocatedUnfairLock<Int>

    init(_ inner: InMemoryStateStore, refusals: Int, wait: Duration = .seconds(40), matching: @escaping @Sendable (String) -> Bool) {
        self.inner = inner
        self.matching = matching
        self.wait = wait
        self.refusals = OSAllocatedUnfairLock(initialState: refusals)
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        try await inner.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await inner.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        let refuse = matching(message) && refusals.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
        if refuse { throw .budgetExhausted(retryAfter: wait) }
        return try await inner.write(path, data: data, replacing: sha, message: message)
    }
}

/// 待たずに、待つはずだった時間を残す。生きている印の間隔だけは、取り消されるまで待つ（印を書き続けないように）
final class WaitRecorder: Sleeper {
    private let state = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    /// 待つときに呼ぶ（待つ間に排他の外にいるかを確かめる）
    let probe: @Sendable () async -> Void

    init(probe: @escaping @Sendable () async -> Void = {}) {
        self.probe = probe
    }

    var waits: [Duration] { state.withLock { $0 } }

    func sleep(for duration: Duration) async throws {
        if duration == JobTiming().heartbeatInterval {
            try await Task.sleep(for: .seconds(3_600))
            return
        }
        await probe()
        state.withLock { $0.append(duration) }
    }
}

/// 書き込みの予算を使い切ったとき、試行と Claude のジョブの結果を捨てずに、待って書き直す
extension ClaudeJobRunnerTests {
    func runner(_ store: any StateStore, claude: any CommandRunning, sleeper: WaitRecorder, lock: CommanderLock) -> ClaudeJobRunner {
        var context = CommanderContext(store: store, mac: Self.commander, lock: lock) { Self.now }
        context.files = StateFileStore(store: store, sleeper: sleeper)
        return ClaudeJobRunner(
            context: context,
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
            workspace: FixedWorkspace(directory: directory),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation])
        )
    }

    @Test func workerWaitsAndWritesFinishedAttemptAfterBudgetIsBack() async throws {
        let given = try await requested()
        let store = ExhaustingStore(given.store, refusals: 2) { $0.hasSuffix(" succeeded") }
        let sleeper = WaitRecorder()
        let recorder = AttemptRecorder(files: StateFileStore(store: store), mac: Self.commander) { Self.now }
        let outputs = AttemptFile.Outputs(pullRequest: 41, commit: String(repeating: "a", count: 40))
        let worker = JobWorker(runner: StubJob { _ in JobResult(outputs: outputs) }, recorder: recorder, sleeper: sleeper) { Self.now }
        let attempt = try #require(try await worker.perform(given.job))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.outputs == outputs)
        #expect(sleeper.waits == [.seconds(40), .seconds(40)])

        // 待ちの上限を超えるなら、待たずに諦める（試行は実行中のまま残り、司令塔が時間切れとして扱う）
        var next = given.job
        next.attempts = 1
        var timing = JobTiming()
        timing.writeWaitLimit = .seconds(30)
        let exhausted = ExhaustingStore(given.store, refusals: 1) { $0.hasSuffix(" succeeded") }
        let impatient = JobWorker(
            runner: StubJob { _ in JobResult() },
            recorder: AttemptRecorder(files: StateFileStore(store: exhausted), mac: Self.commander) { Self.now },
            timing: timing,
            sleeper: WaitRecorder()
        ) { Self.now }
        let refused = CommanderError.files(.store(.budgetExhausted(retryAfter: .seconds(40))))
        await #expect(throws: refused) { try await impatient.perform(next) }
    }

    @Test func claudeResultIsWrittenAfterWaitingOutsideTheLock() async throws {
        let given = try await requested()
        let lock = CommanderLock()
        let held = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let sleeper = WaitRecorder {
            let isHeld = await lock.isHeld
            held.withLock { $0.append(isHeld) }
        }
        let store = ExhaustingStore(given.store, refusals: 1, wait: .seconds(30)) { $0 == "質問を作る" }
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        guard case .written = try await runner(store, claude: claude, sleeper: sleeper, lock: lock).run(given.job) else {
            Issue.record("書けていない")
            return
        }
        // Claude は 1 回だけ呼び、待つ間は排他の外にいる（人の意図の処理を止めない）
        #expect(claude.commands.count == 1)
        #expect(sleeper.waits == [.seconds(30)])
        #expect(held.withLock { $0 } == [false])
        #expect(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, given.epic.id), in: given.store) != nil)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, given.epic.id), in: given.store)?.stage == .checking)
    }

    @Test func moreQuestionsWrittenBeforeBudgetRanOutAreFinished() async throws {
        let given = try await checking()
        // 追加の質問を書いた後、回答に戻す前に予算を使い切った
        let store = ExhaustingStore(given.store, refusals: 1) { $0 == "epic を asking にする" }
        let draft = try Self.decodeDraft(Self.question("q1"))
        let claude = ScriptedRunner([Self.output(CheckReadinessJob.Output(verdict: .moreQuestions, reason: "期間", questions: [draft]))])
        let sleeper = WaitRecorder()
        guard case .written = try await runner(store, claude: claude, sleeper: sleeper, lock: CommanderLock()).run(given.job) else {
            Issue.record("書けていない")
            return
        }
        #expect(claude.commands.count == 1)
        #expect(sleeper.waits == [.seconds(40)])
        let questions = try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, given.epic.id), in: given.store))
        #expect(questions.questions.map(\.state) == [.open])
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, given.epic.id), in: given.store)?.stage == .asking)
    }
}
