import AskHubCommander
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
@testable import AskHubWorker
import CryptoKit
import Foundation
import os
import Testing

/// 呼ばれたジョブを覚えて、決まった結果を返す
final class RecordingJob: JobRunning {
    private let calls = OSAllocatedUnfairLock<[ULID]>(initialState: [])
    let result: JobResult

    init(_ result: JobResult) {
        self.result = result
    }

    var called: [ULID] { calls.withLock { $0 } }

    func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        calls.withLock { $0.append(job.id) }
        return result
    }
}

/// 開けるまで待たせる（動かしている間に司令塔の様子が変わる場合を作る）
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// 呼ばれたジョブを覚えて、門が開くまで待ってから決まった結果を返す
final class GatedJob: JobRunning {
    private let calls = OSAllocatedUnfairLock<[ULID]>(initialState: [])
    let gate = Gate()
    let result: JobResult

    init(_ result: JobResult) {
        self.result = result
    }

    var called: [ULID] { calls.withLock { $0 } }

    func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        calls.withLock { $0.append(job.id) }
        await gate.wait()
        return result
    }
}

/// 司令塔の生きている印の読み取りを、決めた回数だけ失敗させる（GitHub に届かないときを再現する）
actor FlakyCommanderStore: StateStore {
    let base: InMemoryStateStore
    private var failures: Int

    init(_ base: InMemoryStateStore, failures: Int) {
        self.base = base
        self.failures = failures
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        if path == StatePath.commander, failures > 0 {
            failures -= 1
            throw .transport("つながらない")
        }
        return try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await base.list(directory)
    }

    func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await base.listAll(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await base.write(path, data: data, replacing: sha, message: message)
    }

    func snapshot() async throws(StateStoreError) -> any StateStore {
        self
    }
}

struct WorkerLoopTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let mac = MacName(rawValue: "macbook-a")!
    static let other = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let outputs = AttemptFile.Outputs(commit: String(repeating: "d", count: 40), branch: "askhub/01JCJ0A0000000000000000001")

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var verifier: IntentVerifier { IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]) }

    func loop(
        _ store: any StateStore,
        runner: any JobRunning,
        clock: OSAllocatedUnfairLock<Date> = .init(initialState: now)
    ) -> WorkerLoop {
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let verifier = verifier
        return WorkerLoop(
            context: CommanderContext(store: store, mac: Self.mac) { clock.withLock { $0 } },
            settings: .init(kind: .manual, capacity: .init(claude: 1, build: 1), workerVersion: "0.1.0", claudeVersion: "2.1.316"),
            verifier: { verifier },
            runners: [.prepareWorkspace: runner],
            status: { CommanderLoop.MachineStatus(diskFreeGB: 120, load: 3.2, selfCheck: selfCheck, xcodeVersion: "26.6") },
            log: { _ in }
        )
    }

    /// 署名した開始の人の意図を置き、その参照を返す
    func signedOrigin(in store: InMemoryStateStore, nonce: Int) async throws -> IntentReference {
        let nonce = try #require(ULID(rawValue: "01JCJ0C00000000000000000\(String(format: "%02d", nonce))"))
        let envelope = IntentEnvelope(
            kind: "startEpic",
            repo: Self.repo,
            target: nil,
            targetVersion: nil,
            payload: ["mac": .string(Self.mac.rawValue)],
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return IntentReference(keyId: keyID, nonce: nonce)
    }

    /// epic と、その作業場所の用意のジョブを置く
    @discardableResult
    func epic(_ number: Int, on mac: MacName, origin: IntentReference?, in store: InMemoryStateStore) async throws -> JobFile {
        let epic = try #require(ULID(rawValue: "01JCJ0A00000000000000000\(String(format: "%02d", number))"))
        let time = Timestamp(Self.now)
        let file = EpicFile(id: epic, repo: Self.repo, title: "epic \(number)", stage: .running, mac: mac, createdAt: time, updatedAt: time)
        let job = JobFile(
            id: try #require(ULID(rawValue: "01JCJ0B00000000000000000\(String(format: "%02d", number))")),
            kind: .prepareWorkspace,
            repo: Self.repo,
            epic: epic,
            assignedMac: mac,
            needs: .init(claude: false, build: false),
            state: .assigned,
            origin: origin,
            createdAt: time,
            updatedAt: time
        )
        await store.put(StatePath.epic(Self.repo, epic), data: try StateFileCoder.encode(file))
        await store.put(StatePath.job(Self.repo, epic: epic, job: job.id), data: try StateFileCoder.encode(job))
        return job
    }

    /// 司令塔の生きている印を置く（互換の番号を書かない前の版の司令塔は nil）
    func commander(compatibility: Int?, in store: InMemoryStateStore) async throws {
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let versions = CommanderFile.Versions(commander: "0.2.0", compatibility: compatibility)
        let file = CommanderFile(mac: Self.other, seenAt: Timestamp(Self.now), versions: versions, selfCheck: selfCheck)
        await store.put(StatePath.commander, data: try StateFileCoder.encode(file))
    }

    func heartbeat(in store: InMemoryStateStore) async throws -> MacFile {
        try StateFileCoder.decode(MacFile.self, from: #require(await store.data(at: StatePath.mac(Self.mac))))
    }

    func attempt(of job: JobFile, in store: InMemoryStateStore) async throws -> AttemptFile? {
        let path = StatePath.attempt(Self.repo, epic: job.epic, job: job.id, number: 1)
        return try await store.data(at: path).map { try StateFileCoder.decode(AttemptFile.self, from: $0) }
    }

    @Test func picksOwnJobsAndWritesAttemptsWithOutputs() async throws {
        let store = InMemoryStateStore()
        let mine = try await epic(1, on: Self.mac, origin: try await signedOrigin(in: store, nonce: 1), in: store)
        // ほかの Mac が受け持つ epic のジョブは引き受けない
        let others = try await epic(2, on: Self.other, origin: try await signedOrigin(in: store, nonce: 2), in: store)
        let runner = RecordingJob(JobResult(outputs: Self.outputs))
        let loop = loop(store, runner: runner)
        #expect(try await loop.cycle().map(\.id) == [mine.id])
        await loop.waitForJobs()
        #expect(runner.called == [mine.id])
        let attempt = try #require(try await attempt(of: mine, in: store))
        #expect(attempt.mac == Self.mac)
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.outputs == Self.outputs)
        #expect(try await self.attempt(of: others, in: store) == nil)
        // ジョブの状態は書かない（司令塔が試行を読んで決める）
        let job = try #require(await store.data(at: StatePath.job(Self.repo, epic: mine.epic, job: mine.id)))
        #expect(try StateFileCoder.decode(JobFile.self, from: job).state == .assigned)
        // 司令塔がまだ試行を読んでいないジョブは、引き受け直そうとしても同じ番号の試行があるので断られ、もう一度は動かさない
        try await loop.cycle()
        await loop.waitForJobs()
        #expect(runner.called == [mine.id])
    }

    @Test func refusesJobWhoseOriginCannotBeVerified() async throws {
        let store = InMemoryStateStore()
        let forged = IntentReference(keyId: keyID, nonce: try #require(ULID(rawValue: "01JCJ0C0000000000000000099")))
        let job = try await epic(1, on: Self.mac, origin: forged, in: store)
        let runner = RecordingJob(JobResult(outputs: Self.outputs))
        let loop = loop(store, runner: runner)
        try await loop.cycle()
        await loop.waitForJobs()
        // 実行せず、想定外の失敗として人に渡す（黙って止まらない）
        #expect(runner.called.isEmpty)
        let attempt = try #require(try await attempt(of: job, in: store))
        #expect(attempt.outcome == .failed)
        #expect(attempt.failure?.failureClass == .unexpected)
    }

    @Test func writesHeartbeatWithKindAtInterval() async throws {
        let store = InMemoryStateStore()
        let clock = OSAllocatedUnfairLock(initialState: Self.now)
        let loop = loop(store, runner: RecordingJob(JobResult()), clock: clock)
        try await loop.cycle()
        let path = StatePath.mac(Self.mac)
        let mac = try StateFileCoder.decode(MacFile.self, from: #require(await store.data(at: path)))
        #expect(mac.kind == .manual)
        #expect(mac.capacity == .init(claude: 1, build: 1))
        #expect(mac.versions == .init(worker: "0.1.0", compatibility: MachineCompatibility.current, claude: "2.1.316", xcode: "26.6"))
        #expect(mac.refusal == nil)
        #expect(mac.diskFreeGB == 120)
        // 間隔の前には書き直さず、過ぎたら書く
        clock.withLock { $0 = Self.now.addingTimeInterval(5 * 60) }
        try await loop.cycle()
        #expect(try StateFileCoder.decode(MacFile.self, from: #require(await store.data(at: path))).seenAt == Timestamp(Self.now))
        clock.withLock { $0 = Self.now.addingTimeInterval(10 * 60) }
        try await loop.cycle()
        let later = try StateFileCoder.decode(MacFile.self, from: #require(await store.data(at: path)))
        #expect(later.seenAt == Timestamp(Self.now.addingTimeInterval(10 * 60)))
    }

    // MARK: - 互換の番号

    /// 司令塔と互換の番号が合わなければ新しいジョブを引き受けず、理由を生きている印に書く。合ったら、間隔を待たずに印を書き直して引き受ける
    @Test func refusesNewJobsWhileCommanderIsIncompatible() async throws {
        let store = InMemoryStateStore()
        try await commander(compatibility: MachineCompatibility.current + 1, in: store)
        let job = try await epic(1, on: Self.mac, origin: try await signedOrigin(in: store, nonce: 1), in: store)
        let runner = RecordingJob(JobResult(outputs: Self.outputs))
        let loop = loop(store, runner: runner)
        #expect(try await loop.cycle().isEmpty)
        await loop.waitForJobs()
        #expect(runner.called.isEmpty)
        #expect(try await attempt(of: job, in: store) == nil)
        let refusal = try #require(try await heartbeat(in: store).refusal)
        #expect(refusal.reason == .incompatible)
        let (theirs, mine) = (MachineCompatibility.current + 1, MachineCompatibility.current)
        #expect(refusal.message == "司令塔の互換の番号は \(theirs)、このワーカーは \(mine)。ワーカーを更新するまで新しいジョブを引き受けない")

        try await commander(compatibility: MachineCompatibility.current, in: store)
        #expect(try await loop.cycle().map(\.id) == [job.id])
        await loop.waitForJobs()
        #expect(try await heartbeat(in: store).refusal == nil)
        #expect(runner.called == [job.id])
    }

    /// 引き受けないと決めても、動かしているジョブは手放さずに終わらせて試行を書く
    @Test func keepsRunningJobsAfterCommanderBecomesIncompatible() async throws {
        let store = InMemoryStateStore()
        try await commander(compatibility: MachineCompatibility.current, in: store)
        let first = try await epic(1, on: Self.mac, origin: try await signedOrigin(in: store, nonce: 1), in: store)
        let runner = GatedJob(JobResult(outputs: Self.outputs))
        let loop = loop(store, runner: runner)
        #expect(try await loop.cycle().map(\.id) == [first.id])

        try await commander(compatibility: MachineCompatibility.current + 1, in: store)
        let second = try await epic(2, on: Self.mac, origin: try await signedOrigin(in: store, nonce: 2), in: store)
        #expect(try await loop.cycle().isEmpty)
        #expect(try await heartbeat(in: store).refusal?.reason == .incompatible)
        await runner.gate.open()
        await loop.waitForJobs()
        #expect(runner.called == [first.id])
        #expect(try await attempt(of: first, in: store)?.outcome == .succeeded)
        #expect(try await attempt(of: second, in: store) == nil)
    }

    /// 読めない（知らない版の）司令塔の印は、決まりが変わったとみなして引き受けない。番号を書かない前の版の司令塔・印が無いときは照らし合わせない
    @Test func refusesWhenCommanderHeartbeatIsUnreadable() async throws {
        let store = InMemoryStateStore()
        try await epic(1, on: Self.mac, origin: try await signedOrigin(in: store, nonce: 1), in: store)
        await store.put(StatePath.commander, data: Data(#"{"v":2,"mac":"mac-mini"}"#.utf8))
        let loop = loop(store, runner: RecordingJob(JobResult(outputs: Self.outputs)))
        #expect(try await loop.cycle().isEmpty)
        let refusal = try #require(try await heartbeat(in: store).refusal)
        #expect(refusal.reason == .incompatible)
        #expect(refusal.message.hasPrefix("司令塔の生きている印（commander.json）を読めない"))
        // 番号を比べられないので、ワーカーだけを更新すればよいとは言わない
        #expect(refusal.message.contains("ワーカーか司令塔を更新するか、印を直すまで"))

        try await commander(compatibility: nil, in: store)
        #expect(try await loop.cycle().count == 1)
        #expect(try await heartbeat(in: store).refusal == nil)
        await loop.waitForJobs()
        #expect(WorkerLoop.refusal(commander: nil, own: 1) == nil)
    }

    /// 起動してから司令塔の印を読めるまでは、新しいジョブを引き受けない（合わない司令塔のジョブを始めない）。読めた後の失敗では、前の判断のまま
    @Test func waitsForFirstCompatibilityCheckBeforeTakingJobs() async throws {
        let base = InMemoryStateStore()
        try await commander(compatibility: MachineCompatibility.current, in: base)
        let first = try await epic(1, on: Self.mac, origin: try await signedOrigin(in: base, nonce: 1), in: base)
        let runner = RecordingJob(JobResult(outputs: Self.outputs))
        let loop = loop(FlakyCommanderStore(base, failures: 2), runner: runner)
        #expect(try await loop.cycle().isEmpty)
        #expect(runner.called.isEmpty)
        // 生きている印は書く（照らし合わせを待っているだけで、引き受けない理由は書かない）
        #expect(try await heartbeat(in: base).refusal == nil)
        #expect(try await loop.cycle().isEmpty)
        #expect(try await loop.cycle().map(\.id) == [first.id])
        await loop.waitForJobs()
        #expect(runner.called == [first.id])
    }

    /// 合わせるために更新するものを、互換の番号の大小で出す（ワーカーのほうが新しければ司令塔）
    @Test func refusalNamesWhatToUpdate() throws {
        #expect(WorkerLoop.refusal(commander: 1, own: 1) == nil)
        #expect(try #require(WorkerLoop.refusal(commander: 1, own: 2)).message.contains("司令塔を更新するまで"))
        #expect(try #require(WorkerLoop.refusal(commander: 3, own: 2)).message.contains("ワーカーを更新するまで"))
    }
}
