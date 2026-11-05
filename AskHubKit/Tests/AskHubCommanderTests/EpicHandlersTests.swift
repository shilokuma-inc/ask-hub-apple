@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 依頼・開始・ゴールの修正の受け付け
struct EpicHandlersTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let commander = MacName(rawValue: "mac-mini")!
    static let laptop = MacName(rawValue: "macbook")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static var timestamp: Timestamp { Timestamp(now) }

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    private func intake(_ store: InMemoryStateStore) -> IntentIntake {
        IntentIntake(
            context: CommanderContext(store: store, mac: Self.commander) { Self.now },
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["request": RequestHandler(), "startEpic": StartEpicHandler(), "reviseGoal": ReviseGoalHandler()]
        )
    }

    /// 署名した人の意図を `intents/` に置く
    @discardableResult
    private func put(
        _ kind: String,
        target: IntentEnvelope.Target? = nil,
        version: String? = nil,
        payload: [String: JSONValue],
        nonce: ULID = .generate(at: EpicHandlersTests.now),
        in store: InMemoryStateStore
    ) async throws -> ULID {
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: target,
            targetVersion: version,
            payload: payload,
            issuedAt: Self.timestamp,
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return nonce
    }

    private func put<File: StateFile>(_ file: File, at path: String, in store: InMemoryStateStore) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func file<File: StateFile>(_ type: File.Type, at path: String, in store: InMemoryStateStore) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    private func jobs(_ epic: ULID, in store: InMemoryStateStore) async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: epic)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    private func registeredRepository(maxConcurrentEpics: Int = 1) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let repo = RepositoryFile(repo: Self.repo, platform: .apple, maxConcurrentEpics: maxConcurrentEpics, addedAt: Self.timestamp)
        try await put(repo, at: StatePath.repository(Self.repo), in: store)
        return store
    }

    // MARK: - 依頼

    @Test func requestCreatesEpicAndQuestionJob() async throws {
        let store = try await registeredRepository()
        let nonce = try await put("request", payload: ["title": .string("ランキング"), "body": .string("日ごとに入れ替えたい")], in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "request")])
        let epicID = RequestHandler.epicID(for: .init(keyId: keyID, nonce: nonce))
        let epic = try #require(try await file(EpicFile.self, at: StatePath.epic(Self.repo, epicID), in: store))
        #expect(epic.stage == .drafting)
        #expect(epic.title == "ランキング")
        #expect(epic.origin == .init(keyId: keyID, nonce: nonce))
        let job = try #require(try await jobs(epicID, in: store).first)
        #expect(job.kind == .makeQuestions)
        #expect(job.assignedMac == Self.commander)
    }

    @Test func requestIsRejectedForUnregisteredRepository() async throws {
        let store = InMemoryStateStore()
        try await put("request", payload: ["title": .string("ランキング")], in: store)
        let reason = "shilokuma-inc/askhub-sandbox は対象のリポジトリに加えていない"
        #expect(try await intake(store).processPending() == [.rejected(kind: "request", reason: reason)])
    }

    @Test func requestChecksAttachments() async throws {
        let store = try await registeredRepository()
        let data = Data("png".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func payload(size: Int, hash: String) -> [String: JSONValue] {
            let attachment = JSONValue.object([
                "n": .integer(1),
                "name": .string("mock.png"),
                "size": .integer(Int64(size)),
                "sha256": .string(hash)
            ])
            return ["title": .string("…"), "attachments": .array([attachment])]
        }
        func nonce(_ seconds: TimeInterval) -> ULID { .generate(at: Self.now.addingTimeInterval(seconds)) }
        let good = try await put("request", payload: payload(size: data.count, hash: hash), nonce: nonce(0), in: store)
        await store.put(StatePath.attachment(device: keyID, nonce: good, number: 1), data: data)
        let zero = String(repeating: "0", count: 64)
        let wrong = try await put("request", payload: payload(size: data.count, hash: zero), nonce: nonce(1), in: store)
        await store.put(StatePath.attachment(device: keyID, nonce: wrong, number: 1), data: data)
        try await put("request", payload: payload(size: data.count, hash: hash), nonce: nonce(2), in: store)
        #expect(try await intake(store).processPending() == [
            .accepted(kind: "request"),
            .rejected(kind: "request", reason: "添付 1（mock.png）の大きさかハッシュが、依頼と合わない"),
            .rejected(kind: "request", reason: "添付 1（mock.png）が無い")
        ])
    }

    @Test func redoingRequestDoesNotDuplicate() async throws {
        let store = try await registeredRepository()
        let nonce = try await put("request", payload: ["title": .string("ランキング")], in: store)
        let intake = intake(store)
        let stored = try #require(await store.data(at: StatePath.intent(device: keyID, nonce: nonce)))
        let envelope = try intake.verifier.verify(stored: JSONValue(parsing: stored), now: Self.now)
        #expect(try await RequestHandler().handle(envelope, in: intake.context) == .accept)
        #expect(try await intake.processPending() == [.accepted(kind: "request")])
        #expect(try await jobs(RequestHandler.epicID(for: .init(keyId: keyID, nonce: nonce)), in: store).count == 1)
    }

    // MARK: - 開始とゴールの修正

    /// ゴールの確認を待っている epic（ゴールは 2 版）と、生きている Mac
    private func awaitingStart(
        macSeen: TimeInterval = -5 * 60,
        stage: EpicStage = .awaitingStart
    ) async throws -> (InMemoryStateStore, EpicFile) {
        let store = try await registeredRepository()
        let epic = Self.epic(stage: stage)
        try await put(epic, at: StatePath.epic(Self.repo, epic.id), in: store)
        let goal = GoalFile(version: 2, summary: "ランキングを作る", doneWhen: ["…"], tasks: [.init(id: "t1", title: "集計を作る")])
        try await put(goal, at: StatePath.goal(Self.repo, epic.id), in: store)
        let check = SelfCheck(checkedAt: Self.timestamp, keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let mac = MacFile(
            mac: Self.laptop,
            kind: .resident,
            seenAt: Timestamp(Self.now.addingTimeInterval(macSeen)),
            versions: .init(worker: "1.0"),
            diskFreeGB: 200,
            load: 0.2,
            capacity: .init(claude: 1, build: 1),
            selfCheck: check
        )
        try await put(mac, at: StatePath.mac(Self.laptop), in: store)
        return (store, epic)
    }

    private static func epic(stage: EpicStage) -> EpicFile {
        EpicFile(id: .generate(at: now), repo: repo, title: "ランキング", stage: stage, createdAt: timestamp, updatedAt: timestamp)
    }

    private func revise(
        _ epic: EpicFile,
        _ instruction: String,
        nonce: ULID = .generate(at: now),
        in store: InMemoryStateStore
    ) async throws {
        let target = IntentEnvelope.Target(type: "epic", epic: epic.id)
        try await put("reviseGoal", target: target, version: "2", payload: ["instruction": .string(instruction)], nonce: nonce, in: store)
    }

    private func start(_ epic: EpicFile, version: String = "2", mac: String = "macbook", in store: InMemoryStateStore) async throws {
        try await put("startEpic", target: .init(type: "epic", epic: epic.id), version: version, payload: ["mac": .string(mac)], in: store)
    }

    @Test func startRunsEpicOnChosenMac() async throws {
        let (store, epic) = try await awaitingStart()
        try await start(epic, in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "startEpic")])
        let started = try #require(try await file(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store))
        #expect(started.stage == .running)
        #expect(started.mac == Self.laptop)
        #expect(started.goalVersion == 2)
        let job = try #require(try await jobs(epic.id, in: store).first)
        #expect(job.kind == .prepareWorkspace)
        #expect(job.assignedMac == Self.laptop)
        #expect(job.needs == .init(claude: false, build: false))
    }

    @Test func startIsRejectedWhenItCannotRun() async throws {
        var (store, epic) = try await awaitingStart()
        try await start(epic, version: "1", in: store)
        #expect(try await intake(store).processPending().first == .rejected(kind: "startEpic", reason: "ゴールが直された（今の版は 2）。新しいゴールを確かめて開始し直す"))

        (store, epic) = try await awaitingStart(macSeen: -40 * 60)
        try await start(epic, in: store)
        guard case let .rejected(_, reason)? = try await intake(store).processPending().first else { Issue.record("開始してしまった"); return }
        #expect(reason.hasPrefix("Mac macbook がオフライン"))

        (store, epic) = try await awaitingStart()
        try await start(epic, mac: "studio", in: store)
        #expect(try await intake(store).processPending().first == .rejected(kind: "startEpic", reason: "Mac studio が登録されていない"))

        (store, epic) = try await awaitingStart(stage: .asking)
        try await start(epic, in: store)
        #expect(try await intake(store).processPending().first == .rejected(kind: "startEpic", reason: "開始できる段階でない（今は asking）"))
    }

    @Test func startWaitsForOtherRunningEpic() async throws {
        let (store, epic) = try await awaitingStart()
        let other = Self.epic(stage: .finalizing)
        try await put(other, at: StatePath.epic(Self.repo, other.id), in: store)
        try await start(epic, in: store)
        let reason = "同時に回せる epic の上限（1 本）に達している。ほかの epic が終わってから開始する"
        #expect(try await intake(store).processPending().first == .rejected(kind: "startEpic", reason: reason))
    }

    @Test func reviseGoalCreatesJobAndBlocksStartUntilDone() async throws {
        let (store, epic) = try await awaitingStart()
        try await revise(epic, "完了の条件を足して", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "reviseGoal")])
        let job = try #require(try await jobs(epic.id, in: store).first)
        #expect(job.kind == .reviseGoal)
        #expect(job.input?["instruction"] == .string("完了の条件を足して"))
        #expect(job.input?["goalVersion"] == .integer(2))
        // 直している間は、開始も、ほかの指示も受け付けない
        try await start(epic, in: store)
        try await revise(epic, "別の指示", nonce: .generate(at: Self.now.addingTimeInterval(1)), in: store)
        let outcomes = try await intake(store).processPending()
        #expect(outcomes.contains(.rejected(kind: "startEpic", reason: "ゴールを直している途中。直し終えてから開始する")))
        #expect(outcomes.contains(.rejected(kind: "reviseGoal", reason: "ほかの指示でゴールを直している途中。直し終えてから指示し直す")))
    }
}
