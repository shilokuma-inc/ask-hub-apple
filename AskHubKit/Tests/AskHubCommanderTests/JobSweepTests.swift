@testable import AskHubCommander
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 司令塔が試行を読んで、ジョブの状態を決める
extension ClaudeJobRunnerTests {
    func sweep(_ store: InMemoryStateStore, at now: Date = ClaudeJobRunnerTests.now) -> JobSweep {
        JobSweep(context: CommanderContext(store: store, mac: Self.commander) { now })
    }

    func job(_ id: ULID, epic: ULID, in store: InMemoryStateStore) async throws -> JobFile? {
        try await read(JobFile.self, at: StatePath.job(Self.repo, epic: epic, job: id), in: store)
    }

    @Test func sweepFollowsAttemptsOfJob() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        let attempt = try await recorder.start(given.job)
        // 実行中の試行を見て running にする
        #expect(try await sweep(given.store).sweep().map(\.state) == [.running])
        #expect(try await job(given.job.id, epic: given.epic.id, in: given.store)?.attempts == 1)
        // 終わった試行を見て succeeded にする。もう一度見ても変えない
        try await recorder.finish(attempt, of: given.job, failure: nil)
        #expect(try await sweep(given.store).sweep().map(\.state) == [.succeeded])
        #expect(try await sweep(given.store).sweep().isEmpty)
    }

    @Test func sweepRetriesOutageAndHandsUnexpectedToHuman() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        let attempt = try await recorder.start(given.job)
        try await recorder.finish(attempt, of: given.job, failure: AttemptFailure(failureClass: .githubOutage, message: "502"))
        let retried = try #require(try await sweep(given.store).sweep().first)
        #expect(retried.state == .assigned)
        #expect(retried.attempts == 1)
        #expect(retried.nextRunAt == Timestamp(Self.now.addingTimeInterval(60)))

        let second = try await recorder.start(retried)
        try await recorder.finish(second, of: retried, failure: AttemptFailure(failureClass: .unexpected, message: "?"))
        #expect(try await sweep(given.store).sweep().map(\.state) == [.waitingHuman])
    }

    @Test func sweepSkipsFinishedEpics() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        _ = try await recorder.start(given.job)
        var abandoned = given.epic
        abandoned.stage = .abandoned
        try await put(abandoned, at: StatePath.epic(Self.repo, abandoned.id), in: given.store)
        #expect(try await sweep(given.store).sweep().isEmpty)
        #expect(try await job(given.job.id, epic: given.epic.id, in: given.store)?.state == .assigned)
    }

    @Test func pickerWaitsForParentJobToSucceed() async throws {
        // 質問の無い依頼: 質問づくりの結果から作った着手前の確認は、質問づくりのジョブが成功するまで引き受けない
        let given = try await requested()
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        _ = try await worker(given.store, claude: claude).perform(given.job)
        let capacity = MacFile.Capacity(claude: 2, build: 1)
        let before = try await jobs(given.epic.id, in: given.store)
        // 司令塔が試行を読むまでは、質問づくりのジョブは assigned のまま（引き受け直そうとしても、試行がすでにあるので断られる）
        let picked = JobPicker.pick(from: before, for: Self.commander, capacity: capacity, now: Self.now)
        #expect(!picked.contains { $0.kind == .checkReadiness })
        _ = try await sweep(given.store).sweep()
        let after = try await jobs(given.epic.id, in: given.store)
        #expect(JobPicker.pick(from: after, for: Self.commander, capacity: capacity, now: Self.now).map(\.kind) == [.checkReadiness])
    }

    @Test func sweepReadsSnapshotAndRereadsOnlyToWrite() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        _ = try await recorder.start(given.job)
        let probe = SnapshotProbeStore(given.store)
        let sweep = JobSweep(context: CommanderContext(store: probe, mac: Self.commander) { Self.now })
        // epic・ジョブ・試行・Mac の印は写しから読み、元の置き場所は書く前に読み直すときだけ読む
        #expect(try await sweep.sweep().map(\.state) == [.running])
        #expect(await probe.liveReads == 1)
        #expect(try await sweep.sweep().isEmpty)
        #expect(await probe.liveReads == 1)
    }

    @Test func sweepDoesNotOverwriteJobChangedAfterSnapshot() async throws {
        let given = try await requested()
        let recorder = AttemptRecorder(files: StateFileStore(store: given.store), mac: Self.commander) { Self.now }
        _ = try await recorder.start(given.job)
        // 写しを作った後に、ほかの書き手がジョブを取り消した
        var canceled = given.job
        canceled.state = .canceled
        let data = try StateFileCoder.encode(canceled)
        let path = StatePath.job(Self.repo, epic: given.epic.id, job: given.job.id)
        let probe = SnapshotProbeStore(given.store) { await $0.put(path, data: data) }
        let swept = try await JobSweep(context: CommanderContext(store: probe, mac: Self.commander) { Self.now }).sweepAll()
        // 写しで読んだ assigned のジョブから決めた running を、書き換わった後のジョブに書かない（次の周に回す）
        #expect(swept.changed.isEmpty)
        #expect(try await job(given.job.id, epic: given.epic.id, in: given.store)?.state == .canceled)
        #expect(try await sweep(given.store).sweepAll().jobs.map(\.state) == [.canceled])
    }
}

/// 元の置き場所への読み取りを数え、写しを作った直後に `afterSnapshot` を流す（写しで読んだ後に書き換わった状態を再現する）
actor SnapshotProbeStore: StateStore {
    let base: InMemoryStateStore
    private let afterSnapshot: @Sendable (InMemoryStateStore) async -> Void
    private(set) var liveReads = 0

    init(_ base: InMemoryStateStore, afterSnapshot: @escaping @Sendable (InMemoryStateStore) async -> Void = { _ in }) {
        self.base = base
        self.afterSnapshot = afterSnapshot
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        liveReads += 1
        return try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        liveReads += 1
        return try await base.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await base.write(path, data: data, replacing: sha, message: message)
    }

    func snapshot() async throws(StateStoreError) -> any StateStore {
        let snapshot = try await base.snapshot()
        await afterSnapshot(base)
        return snapshot
    }
}
