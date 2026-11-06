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

/// 常駐のループの 1 周（人の意図 → ジョブの見直し → 引き受け）
extension ClaudeJobRunnerTests {
    func loop(_ store: InMemoryStateStore, claude: any CommandRunning, capacity: Int = 2) -> CommanderLoop {
        let context = context(store)
        let publicKeys = [keyID: key.publicKey.derRepresentation]
        let workspace = FixedWorkspace(directory: directory)
        let selfCheck = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        return CommanderLoop(
            context: context,
            settings: .init(capacity: .init(claude: capacity, build: 0), commanderVersion: "0.1.0"),
            verifier: { IntentVerifier(publicKeys: publicKeys) },
            worker: { verifier in
                ClaudeJobWorker(
                    runner: ClaudeJobRunner(
                        context: context,
                        client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
                        workspace: workspace,
                        verifier: verifier
                    ),
                    recorder: AttemptRecorder(files: context.files, mac: Self.commander) { Self.now }
                )
            },
            status: { CommanderLoop.MachineStatus(diskFreeGB: 100, load: 0.5, selfCheck: selfCheck) },
            log: { _ in }
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
