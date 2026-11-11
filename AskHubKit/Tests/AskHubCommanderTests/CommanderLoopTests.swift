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
        mirror: DiscussionMirror? = nil,
        epicWorkspace: (any EpicWorkspace)? = nil,
        claudeVersion: String? = nil,
        sleeper: any Sleeper = TaskSleeper(),
        failingVerifier: CommanderError? = nil,
        verifierCalls: OSAllocatedUnfairLock<Int> = .init(initialState: 0),
        tidy: @escaping @Sendable () async -> Void = {}
    ) -> CommanderLoop {
        let publicKeys = [keyID: key.publicKey.derRepresentation]
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        return CommanderLoop(
            context: CommanderContext(store: store, mac: Self.commander, now: now),
            settings: .init(capacity: .init(claude: capacity, build: 0), commanderVersion: "0.1.0"),
            verifier: { () throws(CommanderError) -> IntentVerifier in
                verifierCalls.withLock { $0 += 1 }
                if let failingVerifier { throw failingVerifier }
                return IntentVerifier(publicKeys: publicKeys)
            },
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
            workspace: FixedWorkspace(directory: directory),
            status: {
                CommanderLoop.MachineStatus(
                    diskFreeGB: 100, load: 0.5, selfCheck: selfCheck, claudeVersion: claudeVersion, xcodeVersion: "27.1"
                )
            },
            log: { _ in },
            sleeper: sleeper,
            mirror: mirror,
            epicWorkspace: epicWorkspace,
            tidy: tidy
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

    @Test func restEndsEarlyWhenNewIntentArrives() async throws {
        let store = InMemoryStateStore()
        let sleeper = WaitRecorder()
        let loop = loop(store, claude: ScriptedRunner([]), sleeper: sleeper)
        _ = try await loop.cycle()
        // 意図が無ければ、5 秒ごとに見ながら 30 秒休む
        try await loop.rest()
        #expect(sleeper.waits == Array(repeating: .seconds(5), count: 6))
        // 休む前に届いていれば、休まずに次の周へ
        let request = try await storeWithRequest()
        for path in try await request.listFiles(under: StatePath.intents)?.map(\.path) ?? [] {
            let blob = try #require(try await request.read(path))
            await store.put(path, data: blob.data)
        }
        try await loop.rest()
        #expect(sleeper.waits.count == 6)
    }

    @Test func restDoesNotEndEarlyForIntentsSeenInLastCycle() async throws {
        // 扱えずに残した意図（読めない意図など）では切り上げない（休まずに回り続けないように）
        let store = InMemoryStateStore()
        await store.put(StatePath.intent(device: keyID, nonce: ULID.generate(at: Self.now)), data: Data("not json".utf8))
        let sleeper = WaitRecorder()
        let loop = loop(store, claude: ScriptedRunner([]), sleeper: sleeper)
        _ = try await loop.cycle()
        try await loop.rest()
        #expect(sleeper.waits == Array(repeating: .seconds(5), count: 6))
    }

    @Test func failedCycleRestsWithoutEarlyWake() {
        // 上限なら言われた時間（長すぎれば 15 分まで）、短ければ 1 周の間隔。ほかの失敗も 1 周の間隔
        let poll: Duration = .seconds(30)
        #expect(CommanderLoop.wait(after: .store(.rateLimited(retryAfter: .seconds(120))), pollInterval: poll) == .seconds(120))
        #expect(CommanderLoop.wait(after: .store(.rateLimited(retryAfter: .seconds(1_574))), pollInterval: poll) == .seconds(15 * 60))
        #expect(CommanderLoop.wait(after: .store(.budgetExhausted(retryAfter: .seconds(6))), pollInterval: poll) == poll)
        #expect(CommanderLoop.wait(after: .files(.store(.rateLimited(retryAfter: .seconds(90)))), pollInterval: poll) == .seconds(90))
        #expect(CommanderLoop.wait(after: .store(.invalidPath), pollInterval: poll) == poll)
    }

    @Test func runDoesNotCutRestShortAfterFailedCycle() async throws {
        // 意図を受け付ける前に失敗する（鍵を読めない）と、前の周で見た意図の記録は古いまま。届いている依頼で休みを切り上げず、言われた時間を待つ
        let store = try await storeWithRequest()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let sleeper = HoldingSleeper()
        let loop = loop(
            store,
            claude: ScriptedRunner([]),
            sleeper: sleeper,
            failingVerifier: .store(.rateLimited(retryAfter: .seconds(120))),
            verifierCalls: calls
        )
        let running = Task { await loop.run() }
        for _ in 0..<200 where sleeper.waits.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        running.cancel()
        await running.value
        #expect(sleeper.waits == [.seconds(120)])
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func reportsOnlySlowCycles() {
        let steps: [(name: String, duration: Duration)] = [("人の意図", .milliseconds(1_200)), ("ジョブの見回り", .seconds(40))]
        #expect(CycleTimer.report(steps: steps, total: .seconds(19)) == nil)
        #expect(CycleTimer.report(steps: steps, total: .milliseconds(41_200)) == "1 周に 41.2 秒かかった（人の意図 1.2 秒・ジョブの見回り 40.0 秒）")
    }

    @Test func workerSharesLockWithIntake() async throws {
        // Claude の結果を書く処理と人の意図の処理は、同じ排他を使う（読み直してから書くまでに答え直しが割り込まない）
        let loop = loop(InMemoryStateStore(), claude: ScriptedRunner([]))
        let worker = loop.worker(IntentVerifier(publicKeys: [:]))
        let claude = (worker.runner as? JobDispatcher)?.runners[.makeQuestions] as? ClaudeJobRunner
        #expect(claude?.context.lock === loop.context.lock)
        #expect(worker.recorder.mac == Self.commander)
    }

    @Test func loopPreparesWorkspaceOnlyWithEpicWorkspace() async throws {
        // 常時オンの Mac が開始のときに選ばれたら、司令塔が作業場所の用意も引き受ける（作業場所を渡したときだけ）
        let plain = loop(InMemoryStateStore(), claude: ScriptedRunner([]))
        #expect(!plain.slots.kinds.contains(.prepareWorkspace))
        let git = GitRepositoryWorkspace(setup: .init(root: directory, credentialHelper: "!x git-credential"), runner: FakeGit())
        let preparing = loop(InMemoryStateStore(), claude: ScriptedRunner([]), epicWorkspace: git)
        #expect(preparing.slots.kinds == CommanderLoop.claudeKinds.union([.prepareWorkspace]))
        let runners = (preparing.worker(IntentVerifier(publicKeys: [:])).runner as? JobDispatcher)?.runners
        #expect(runners?[.prepareWorkspace] is PrepareWorkspaceRunner)
    }

    @Test func loopStartsFirstTaskAfterWorkspaceIsPrepared() async throws {
        // 作業場所の用意の成功を読んだ同じ周で、作業ブランチを書き、最初のタスクの実装を epic の Mac に作る
        let store = try await storeWithRequest(count: 0)
        let time = Timestamp(Self.now)
        let laptop = EpicHandlersTests.laptop
        let epic = EpicFile(
            id: .generate(at: Self.now),
            repo: Self.repo,
            title: "ランキング",
            stage: .running,
            mac: laptop,
            createdAt: time,
            updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, epic.id), in: store)
        let goal = GoalFile(version: 1, summary: "…", doneWhen: ["…"], tasks: [.init(id: "t1", title: "集計を作る")])
        try await put(goal, at: StatePath.goal(Self.repo, epic.id), in: store)
        let context = CommanderContext(store: store, mac: Self.commander) { Self.now }
        let spec = JobSpec(kind: .prepareWorkspace, mac: laptop, needs: .init(claude: false, build: false))
        let prepare = context.job(spec, for: epic, origin: IntentReference(keyId: keyID, nonce: .generate(at: Self.now)), seed: "")
        try await put(prepare, at: StatePath.job(Self.repo, epic: epic.id, job: prepare.id), in: store)
        let outputs = AttemptFile.Outputs(commit: String(repeating: "0", count: 40), branch: "askhub/\(epic.id)")
        let attempt = AttemptFile(
            job: prepare.id,
            number: 1,
            mac: laptop,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: outputs
        )
        try await put(attempt, at: StatePath.attempt(Self.repo, epic: epic.id, job: prepare.id, number: 1), in: store)

        // ほかの Mac のジョブなので、司令塔は引き受けない
        #expect(try await loop(store, claude: ScriptedRunner([])).cycle().isEmpty)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.branch == "askhub/\(epic.id)")
        let implement = try #require(try await jobs(epic.id, in: store).first { $0.kind == .implementTask })
        #expect(implement.task == "t1")
        #expect(implement.assignedMac == laptop)
    }

    @Test func loopWritesHeartbeatsAtInterval() async throws {
        let store = try await storeWithRequest(count: 0)
        let loop = loop(store, claude: ScriptedRunner([]), claudeVersion: "2.1.320")
        _ = try await loop.cycle()
        let commander = try #require(try await read(CommanderFile.self, at: StatePath.commander, in: store))
        #expect(commander.mac == Self.commander)
        #expect(commander.versions.commander == "0.1.0")
        // claude の版は、印を書くときに測ったものを書く（人が入れ替えたら次の印で分かる）
        #expect(commander.versions.claude == "2.1.320")
        let mac = try #require(try await read(MacFile.self, at: StatePath.mac(Self.commander), in: store))
        #expect(mac.versions.claude == "2.1.320")
        // ワーカーがビルドとテストに使う Xcode の版も、印を書くときに測ったものを書く（xcode-select を切り替えたら次の印で分かる）
        #expect(mac.versions.xcode == "27.1")
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
        let tidied = OSAllocatedUnfairLock(initialState: 0)
        let loop = loop(store, claude: ScriptedRunner([]), now: { clock.withLock { $0 } }, tidy: { tidied.withLock { $0 += 1 } })
        _ = try await loop.cycle()
        _ = try await loop.cycle()
        // 終わった epic の残りものは、生きている印を書いたときだけ片付ける
        #expect(tidied.withLock { $0 } == 1)
        let later = Self.now.addingTimeInterval(10 * 60 + 1)
        clock.withLock { $0 = later }
        _ = try await loop.cycle()
        #expect(try await read(CommanderFile.self, at: StatePath.commander, in: store)?.seenAt == Timestamp(later))
        #expect(try await read(MacFile.self, at: StatePath.mac(Self.commander), in: store)?.seenAt == Timestamp(later))
        #expect(tidied.withLock { $0 } == 2)
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

/// 待つ時間を残し、取り消されるまで待ち続ける（ループが休みに入ったところで止める）
final class HoldingSleeper: Sleeper {
    private let state = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var waits: [Duration] { state.withLock { $0 } }

    func sleep(for duration: Duration) async throws {
        state.withLock { $0.append(duration) }
        try await Task.sleep(for: .seconds(3_600))
    }
}
