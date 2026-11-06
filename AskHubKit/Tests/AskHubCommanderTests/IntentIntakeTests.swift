@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

struct IntentIntakeTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let epic = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let mac = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600) // 2026-11-04T02:00:00Z

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    private func setUp(_ drafts: [QuestionDraft], stage: EpicStage = .asking) async throws -> (IntentIntake, InMemoryStateStore) {
        let store = InMemoryStateStore()
        let timestamp = Timestamp(Self.now)
        let epicFile = EpicFile(id: Self.epic, repo: Self.repo, title: "ランキング", stage: stage, createdAt: timestamp, updatedAt: timestamp)
        await store.put(StatePath.epic(Self.repo, Self.epic), data: try StateFileCoder.encode(epicFile))
        let questions = try QuestionFlow.start(drafts).questions
        await store.put(StatePath.questions(Self.repo, Self.epic), data: try StateFileCoder.encode(questions))
        let context = CommanderContext(store: store, mac: Self.mac) { Self.now }
        let verifier = IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation])
        return (IntentIntake(context: context, verifier: verifier, handlers: ["answer": AnswerHandler()]), store)
    }

    /// 署名した回答の意図を `intents/` に置く
    @discardableResult
    private func put(
        _ question: String,
        mode: String = "answer",
        choice: String? = "案1",
        version: String = "1",
        issued: Date = IntentIntakeTests.now,
        nonce: ULID = .generate(at: IntentIntakeTests.now),
        signingKey: P256.Signing.PrivateKey? = nil,
        in store: InMemoryStateStore
    ) async throws -> ULID {
        var payload: [String: JSONValue] = ["mode": .string(mode)]
        if let choice, mode == "answer" { payload["choice"] = .string(choice) }
        let envelope = IntentEnvelope(
            kind: "answer",
            repo: Self.repo,
            target: .init(type: "question", epic: Self.epic, id: question),
            targetVersion: version,
            payload: payload,
            issuedAt: Timestamp(issued),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let signature = try IntentSignature.sign(envelope: value, with: signingKey ?? key)
        let stored = JSONValue.object(["envelope": value, "sig": .string(signature)])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return nonce
    }

    private func questions(in store: InMemoryStateStore) async throws -> QuestionsFile {
        try StateFileCoder.decode(QuestionsFile.self, from: #require(await store.data(at: StatePath.questions(Self.repo, Self.epic))))
    }

    private func consumed(_ nonce: ULID, in store: InMemoryStateStore) async throws -> ConsumedIntentFile? {
        let data = await store.data(at: StatePath.consumed(device: keyID, nonce: nonce))
        return try data.map { try StateFileCoder.decode(ConsumedIntentFile.self, from: $0) }
    }

    private func jobs(in store: InMemoryStateStore) async throws -> [JobFile] {
        let entries = try await store.list(StatePath.jobs(Self.repo, epic: Self.epic)) ?? []
        var jobs: [JobFile] = []
        for entry in entries {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    private func draft(_ id: String, dependsOn: [String] = []) -> QuestionDraft {
        QuestionJobsTests.draft(id, dependsOn: dependsOn)
    }

    // MARK: - 受け付け

    @Test func acceptsAnswerAndRecordsIt() async throws {
        let (intake, store) = try await setUp([draft("q1"), draft("q2")])
        let nonce = try await put("q1", in: store)
        #expect(try await intake.processPending() == [.accepted(kind: "answer")])
        #expect(try await questions(in: store).question("q1")?.state == .answered)
        #expect(try await consumed(nonce, in: store)?.result == .accepted)
        #expect(try await intake.pending().isEmpty)
    }

    @Test func createsReviseJobForUnlockedQuestionOnCommanderMac() async throws {
        let (intake, store) = try await setUp([draft("q1"), draft("q2", dependsOn: ["q1"])])
        let nonce = try await put("q1", in: store)
        _ = try await intake.processPending()
        let job = try #require(try await jobs(in: store).first)
        #expect(job.kind == .reviseQuestion)
        #expect(job.assignedMac == Self.mac)
        #expect(job.needs == .init(claude: true, build: false))
        #expect(job.input?["question"] == .string("q2"))
        #expect(job.origin?.nonce == nonce)
        #expect(try await questions(in: store).question("q2")?.state == .revising)
    }

    @Test func lastAnswerStartsReadinessCheck() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        try await put("q1", in: store)
        _ = try await intake.processPending()
        #expect(try await jobs(in: store).map(\.kind) == [.checkReadiness])
        let epic = try StateFileCoder.decode(EpicFile.self, from: #require(await store.data(at: StatePath.epic(Self.repo, Self.epic))))
        #expect(epic.stage == .checking)
    }

    @Test func clarifyCreatesExplainJob() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        try await put("q1", mode: "clarify", choice: nil, in: store)
        _ = try await intake.processPending()
        #expect(try await jobs(in: store).map(\.kind) == [.explain])
        #expect(try await questions(in: store).question("q1")?.state == .clarifying)
    }

    // MARK: - 受け付けない・扱わない

    @Test func recordsRejectionWithReason() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        let nonce = try await put("q1", version: "2", in: store)
        #expect(try await intake.processPending() == [.rejected(kind: "answer", reason: "質問 q1 は書き直された（今の版は 1）。新しい質問に答え直す")])
        #expect(try await consumed(nonce, in: store)?.reason?.contains("書き直された") == true)
        #expect(try await questions(in: store).question("q1")?.state == .open)
    }

    @Test func recordsExpiredIntentAsRejected() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        let nonce = try await put("q1", issued: Self.now.addingTimeInterval(-8 * 24 * 60 * 60), in: store)
        #expect(try await intake.processPending() == [.rejected(kind: "answer", reason: "有効期間（7 日）を過ぎている")])
        #expect(try await consumed(nonce, in: store)?.result == .rejected)
    }

    @Test func ignoresIntentWithoutValidSignatureAndDoesNotRecordIt() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        let nonce = try await put("q1", signingKey: P256.Signing.PrivateKey(), in: store)
        guard case .ignored? = try await intake.processPending().first else { Issue.record("扱ってしまった"); return }
        #expect(try await consumed(nonce, in: store) == nil)
        #expect(try await questions(in: store).question("q1")?.state == .open)
    }

    @Test func ignoresIntentPlacedUnderAnotherNonce() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        let nonce = try await put("q1", in: store)
        // 同じ中身を別の番号の場所に写しても、別の意図としては扱わない
        let copy = ULID.generate(at: Self.now)
        let original = try #require(await store.data(at: StatePath.intent(device: keyID, nonce: nonce)))
        await store.put(StatePath.intent(device: keyID, nonce: copy), data: original)
        let outcomes = try await intake.processPending()
        #expect(outcomes.contains(.accepted(kind: "answer")))
        #expect(outcomes.contains(.ignored(reason: "置き場所と封筒が合わない")))
        #expect(try await consumed(copy, in: store) == nil)
    }

    // MARK: - やり直し

    @Test func processesInNonceOrder() async throws {
        let (intake, store) = try await setUp([draft("q1")])
        // 後の答え（案2）を先に置いても、番号の順に処理するので、最後の答えが残る
        try await put("q1", choice: "案2", nonce: .generate(at: Self.now.addingTimeInterval(1)), in: store)
        try await put("q1", choice: "案1", nonce: .generate(at: Self.now), in: store)
        _ = try await intake.processPending()
        #expect(try await questions(in: store).question("q1")?.answer?.choice == "案2")
    }

    @Test func redoingAfterStopBeforeRecordDoesNotDuplicate() async throws {
        let (intake, store) = try await setUp([draft("q1"), draft("q2", dependsOn: ["q1"])])
        let nonce = try await put("q1", in: store)
        // 処理した記録を書く前に止まった、とみなして処理だけを 2 回行う
        let envelope = try intake.verifier.verify(
            stored: JSONValue(parsing: #require(await store.data(at: StatePath.intent(device: keyID, nonce: nonce)))), now: Self.now
        )
        #expect(try await AnswerHandler().handle(envelope, in: intake.context) == .accept)
        #expect(try await intake.processPending() == [.accepted(kind: "answer")])
        #expect(try await jobs(in: store).count == 1)
    }

    @Test func redoingReopenKeepsReadinessJobOfSameAnswer() async throws {
        let (intake, store) = try await setUp([draft("q1")], stage: .awaitingStart)
        // q1 に答えた後（着手前の確認の後）に、答え直す
        var file = try await questions(in: store)
        file = try QuestionFlow.accept(
            QuestionJobsTests.answer("q1", intent: 1), epic: QuestionJobsTests.epicFile(), questions: file, at: Timestamp(Self.now)
        ).questions
        await store.put(StatePath.questions(Self.repo, Self.epic), data: try StateFileCoder.encode(file))
        let nonce = try await put("q1", choice: "案2", in: store)
        let stored = try #require(await store.data(at: StatePath.intent(device: keyID, nonce: nonce)))
        let envelope = try intake.verifier.verify(stored: JSONValue(parsing: stored), now: Self.now)
        // 質問の一覧を書く前に止まったとみなし、処理を 2 回行う
        var context = intake.context
        context.files = StateFileStore(store: FailingQuestionsWrite(base: store))
        await #expect(throws: (any Error).self) { try await AnswerHandler().handle(envelope, in: context) }
        #expect(try await intake.processPending() == [.accepted(kind: "answer")])
        let readiness = try await jobs(in: store).filter { $0.kind == .checkReadiness }
        #expect(readiness.map(\.state) == [.assigned])
        let epic = try StateFileCoder.decode(EpicFile.self, from: #require(await store.data(at: StatePath.epic(Self.repo, Self.epic))))
        #expect(epic.stage == .checking)
    }

    @Test func jobIDsDifferBetweenKeysWithSameNonce() {
        let context = CommanderContext(store: InMemoryStateStore(), mac: Self.mac) { Self.now }
        let epic = QuestionJobsTests.epicFile()
        let nonce = ULID.generate(at: Self.now)
        let first = context.claudeJob(.explain, for: epic, origin: .init(keyId: keyID, nonce: nonce), seed: "q1", input: [:])
        let other = KeyID(rawValue: String(repeating: "z", count: 43))!
        let second = context.claudeJob(.explain, for: epic, origin: .init(keyId: other, nonce: nonce), seed: "q1", input: [:])
        #expect(first.id != second.id)
    }

    // MARK: - ULID

    @Test func generatesAndDerivesULIDs() throws {
        #expect(ULID(milliseconds: 0, randomness: Array(repeating: 0, count: 10)).rawValue == "00000000000000000000000000")
        #expect(ULID(milliseconds: (1 << 48) - 1, randomness: Array(repeating: 255, count: 10)).rawValue == "7ZZZZZZZZZZZZZZZZZZZZZZZZZ")
        let base = ULID.generate(at: Self.now)
        #expect(base.milliseconds == 1_793_757_600_000)
        let first = ULID.derived(from: base, seed: "explain/q1")
        #expect(first == ULID.derived(from: base, seed: "explain/q1"))
        #expect(first != ULID.derived(from: base, seed: "explain/q2"))
        #expect(first.milliseconds == base.milliseconds)
    }
}

private extension QuestionsFile {
    func question(_ id: String) -> Question? {
        questions.first { $0.id == id }
    }
}

/// 質問の一覧の書き込みだけを失敗させる（処理の途中で止まったときの代わり）
private struct FailingQuestionsWrite: StateStore {
    let base: InMemoryStateStore

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? { try await base.read(path) }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? { try await base.list(directory) }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        guard !path.hasSuffix("/questions.json") else { throw .transport("止まった") }
        return try await base.write(path, data: data, replacing: sha, message: message)
    }
}
