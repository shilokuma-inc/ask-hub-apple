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
        _ store: InMemoryStateStore,
        runner: RecordingJob,
        clock: OSAllocatedUnfairLock<Date> = .init(initialState: now)
    ) -> WorkerLoop {
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let verifier = verifier
        return WorkerLoop(
            context: CommanderContext(store: store, mac: Self.mac) { clock.withLock { $0 } },
            settings: .init(kind: .manual, capacity: .init(claude: 1, build: 1), workerVersion: "0.1.0", claudeVersion: "2.1.316"),
            verifier: { verifier },
            runners: [.prepareWorkspace: runner],
            status: { CommanderLoop.MachineStatus(diskFreeGB: 120, load: 3.2, selfCheck: selfCheck) },
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
        #expect(mac.versions == .init(worker: "0.1.0", claude: "2.1.316"))
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
}
