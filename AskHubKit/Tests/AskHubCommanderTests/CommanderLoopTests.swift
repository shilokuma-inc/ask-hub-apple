import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// 開けるまで Claude の結果を返さない（ジョブを動かしたままにする）
final class GatedRunner: CommandRunning {
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    private let inner: ScriptedRunner

    init(_ results: [CommandResult]) {
        (gate, opener) = AsyncStream<Void>.makeStream()
        inner = ScriptedRunner(results)
    }

    var commands: [Command] { inner.commands }

    func open() {
        opener.finish()
    }

    func run(_ command: Command) async throws -> CommandResult {
        for await _ in gate {}
        return try await inner.run(command)
    }
}

/// 試行のファイルの書き込みを、開けるまで止める（ワーカーが試行を作る前の様子を作る）
final class AttemptGateStore: StateStore {
    let inner: InMemoryStateStore
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    private let reached = OSAllocatedUnfairLock(initialState: false)

    init(_ inner: InMemoryStateStore) {
        self.inner = inner
        (gate, opener) = AsyncStream<Void>.makeStream()
    }

    /// 試行を書こうとして止まっているか
    var isHolding: Bool { reached.withLock { $0 } }

    func open() {
        opener.finish()
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        try await inner.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await inner.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        if path.contains("/attempts/") {
            reached.withLock { $0 = true }
            for await _ in gate {}
        }
        return try await inner.write(path, data: data, replacing: sha, message: message)
    }

    func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await inner.listFiles(under: directory)
    }

    func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await inner.listAll(directory)
    }
}

/// 常駐のループの 1 周（人の意図 → ジョブの見直し → 引き受け）
extension ClaudeJobRunnerTests {
    func loop(
        _ store: any StateStore,
        claude: any CommandRunning,
        capacity: Int = 2,
        now: @escaping @Sendable () -> Date = { ClaudeJobRunnerTests.now },
        mirror: DiscussionMirror? = nil
    ) -> CommanderLoop {
        let publicKeys = [keyID: key.publicKey.derRepresentation]
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        return CommanderLoop(
            context: CommanderContext(store: store, mac: Self.commander, now: now),
            settings: .init(capacity: .init(claude: capacity, build: 0), commanderVersion: "0.1.0"),
            verifier: { IntentVerifier(publicKeys: publicKeys) },
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
            workspace: FixedWorkspace(directory: directory),
            status: { CommanderLoop.MachineStatus(diskFreeGB: 100, load: 0.5, selfCheck: selfCheck) },
            log: { _ in },
            mirror: mirror
        )
    }

    /// 対象のリポジトリを加え、署名した依頼を置く
    func storeWithRequest(count: Int = 1) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, maxConcurrentEpics: 1, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        for number in 0..<count {
            let nonce = ULID.generate(at: Self.now.addingTimeInterval(Double(number)))
            let payload: [String: JSONValue] = ["title": .string("ランキング \(number)"), "body": .string("日ごとに入れ替えたい")]
            let envelope = IntentEnvelope(
                kind: "request", repo: Self.repo, payload: payload, issuedAt: Timestamp(Self.now), nonce: nonce, keyId: keyID
            )
            let value = try envelope.jsonValue()
            let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
            await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        }
        return store
    }

    func epics(in store: InMemoryStateStore) async throws -> [EpicFile] {
        var epics: [EpicFile] = []
        for entry in try await store.list(StatePath.epics(Self.repo)) ?? [] where entry.kind == .directory {
            if let id = ULID(rawValue: entry.name), let epic = try await read(EpicFile.self, at: StatePath.epic(Self.repo, id), in: store) {
                epics.append(epic)
            }
        }
        return epics
    }

    @Test func loopTakesRequestToGoal() async throws {
        let store = try await storeWithRequest()
        let claude = ScriptedRunner([
            QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#),
            Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))
        ])
        let loop = loop(store, claude: claude)
        // 1 周目: 依頼を受け付け、質問づくりを引き受ける
        #expect(try await loop.cycle().map(\.kind) == [.makeQuestions])
        await loop.waitForJobs()
        // 2 周目: 質問づくりの成功を読み、着手前の確認を引き受ける
        #expect(try await loop.cycle().map(\.kind) == [.checkReadiness])
        await loop.waitForJobs()
        _ = try await loop.cycle()
        let epic = try #require(try await epics(in: store).first)
        #expect(epic.stage == .awaitingStart)
        #expect(try await jobs(epic.id, in: store).allSatisfy { $0.state == .succeeded })
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func workerSharesLockWithIntake() async throws {
        // Claude の結果を書く処理と人の意図の処理は、同じ排他を使う（読み直してから書くまでに答え直しが割り込まない）
        let loop = loop(InMemoryStateStore(), claude: ScriptedRunner([]))
        let worker = loop.worker(IntentVerifier(publicKeys: [:]))
        #expect((worker.runner as? ClaudeJobRunner)?.context.lock === loop.context.lock)
        #expect(worker.recorder.mac == Self.commander)
    }

    @Test func loopWritesHeartbeatsAtInterval() async throws {
        let store = try await storeWithRequest(count: 0)
        let loop = loop(store, claude: ScriptedRunner([]))
        _ = try await loop.cycle()
        let commander = try #require(try await read(CommanderFile.self, at: StatePath.commander, in: store))
        #expect(commander.mac == Self.commander)
        #expect(commander.versions.commander == "0.1.0")
        let mac = try #require(try await read(MacFile.self, at: StatePath.mac(Self.commander), in: store))
        #expect(mac.kind == .alwaysOn)
        #expect(mac.capacity == .init(claude: 2, build: 0))
        // 間隔の前には書き直さない
        var older = commander
        older.versions.commander = "0.0.9"
        try await put(older, at: StatePath.commander, in: store)
        _ = try await loop.cycle()
        #expect(try await read(CommanderFile.self, at: StatePath.commander, in: store)?.versions.commander == "0.0.9")
    }

    @Test func loopRewritesHeartbeatsAfterInterval() async throws {
        let store = try await storeWithRequest(count: 0)
        let clock = OSAllocatedUnfairLock(initialState: Self.now)
        let loop = loop(store, claude: ScriptedRunner([]), now: { clock.withLock { $0 } })
        _ = try await loop.cycle()
        let later = Self.now.addingTimeInterval(10 * 60 + 1)
        clock.withLock { $0 = later }
        _ = try await loop.cycle()
        #expect(try await read(CommanderFile.self, at: StatePath.commander, in: store)?.seenAt == Timestamp(later))
        #expect(try await read(MacFile.self, at: StatePath.mac(Self.commander), in: store)?.seenAt == Timestamp(later))
    }

    @Test func loopDoesNotTakeAnotherJobBeforeAttemptIsWritten() async throws {
        let inner = try await storeWithRequest(count: 2)
        let store = AttemptGateStore(inner)
        let summary = QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)
        let loop = loop(store, claude: ScriptedRunner([summary, summary]), capacity: 1)
        #expect(try await loop.cycle().count == 1)
        var waited = 0
        while !store.isHolding, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(store.isHolding)
        // 試行がまだ無く、ジョブが assigned のままでも、動かしているぶん空きは無い
        let epics = try await epics(in: inner)
        var states: [JobState] = []
        for epic in epics { states += try await jobs(epic.id, in: inner).map(\.state) }
        #expect(states == [.assigned, .assigned])
        #expect(try await loop.cycle().isEmpty)
        store.open()
        await loop.waitForJobs()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func loopIgnoresKindsItDoesNotHandle() async throws {
        let store = try await storeWithRequest()
        let intake = IntentIntake(
            context: context(store),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["request": RequestHandler()]
        )
        _ = try await intake.processPending()
        let epic = try #require(try await epics(in: store).first)
        // この Mac が引き受けない種類のジョブ（先に作られ、優先も高い）が、空きを取らない
        let other = JobFile(
            id: ULID.generate(at: Self.now.addingTimeInterval(-60)),
            kind: .notify,
            repo: Self.repo,
            epic: epic.id,
            assignedMac: Self.commander,
            needs: .init(claude: true, build: false),
            state: .assigned,
            createdAt: Timestamp(Self.now.addingTimeInterval(-60)),
            updatedAt: Timestamp(Self.now.addingTimeInterval(-60))
        )
        try await put(other, at: StatePath.job(Self.repo, epic: epic.id, job: other.id), in: store)
        let loop = loop(store, claude: ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)]), capacity: 1)
        #expect(try await loop.cycle().map(\.kind) == [.makeQuestions])
        await loop.waitForJobs()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func loopKeepsCapacityWhileJobsRun() async throws {
        let store = try await storeWithRequest(count: 2)
        let claude = GatedRunner([
            QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#),
            QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)
        ])
        let loop = loop(store, claude: claude, capacity: 1)
        #expect(try await loop.cycle().count == 1)
        // 動かしている間は、司令塔がまだ試行を読んでいなくても、空きを使い切ったとみなす
        #expect(try await loop.cycle().isEmpty)
        claude.open()
        await loop.waitForJobs()
        // 終わったら空きが戻り、次の 1 つ（もう 1 つの依頼の質問づくりか、1 つ目の着手前の確認）を引き受ける
        #expect(try await loop.cycle().count == 1)
        await loop.waitForJobs()
        try? FileManager.default.removeItem(at: directory)
    }
}
