@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人に渡したジョブのやり直し（`retry`）とやめる（`giveUp`）の受け付け
struct JobHandlersTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let commander = MacName(rawValue: "mac-mini")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static var timestamp: Timestamp { Timestamp(now) }

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    private func intake(_ store: any StateStore) -> IntentIntake {
        IntentIntake(
            context: CommanderContext(store: store, mac: Self.commander) { Self.now },
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["retry": RetryJobHandler(), "giveUp": GiveUpJobHandler()]
        )
    }

    /// 署名したやり直し（やめる）の意図を `intents/` に置く
    private func retry(
        _ job: JobFile,
        attempt: Int,
        kind: String = "retry",
        payload: [String: JSONValue] = [:],
        in store: InMemoryStateStore
    ) async throws {
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: .init(type: "job", epic: job.epic, id: job.id.rawValue),
            targetVersion: String(attempt),
            payload: payload,
            issuedAt: Self.timestamp,
            nonce: .generate(at: Self.now),
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: envelope.nonce), data: CanonicalJSON.data(for: stored))
    }

    /// 質問づくりのジョブが、試行 `attempts` 回で `state` になっている epic
    private func waitingJob(
        _ kind: JobKind = .makeQuestions,
        stage: EpicStage = .drafting,
        state: JobState = .waitingHuman,
        attempts: Int = 1,
        input: [String: JSONValue]? = nil,
        epic: EpicFile? = nil,
        in store: InMemoryStateStore = InMemoryStateStore()
    ) async throws -> (InMemoryStateStore, JobFile) {
        let time = Self.timestamp
        let epic = epic
            ?? EpicFile(id: .generate(at: Self.now), repo: Self.repo, title: "ランキング", stage: stage, createdAt: time, updatedAt: time)
        await store.put(StatePath.epic(Self.repo, epic.id), data: try StateFileCoder.encode(epic))
        let job = JobFile(
            id: .generate(at: Self.now),
            kind: kind,
            repo: Self.repo,
            epic: epic.id,
            assignedMac: Self.commander,
            needs: .init(claude: true, build: false),
            state: state,
            attempts: attempts,
            input: input,
            createdAt: Self.timestamp,
            updatedAt: Self.timestamp
        )
        await store.put(StatePath.job(Self.repo, epic: epic.id, job: job.id), data: try StateFileCoder.encode(job))
        return (store, job)
    }

    private func epic(of job: JobFile, in store: InMemoryStateStore) async throws -> EpicFile {
        try StateFileCoder.decode(EpicFile.self, from: #require(await store.data(at: StatePath.epic(Self.repo, job.epic))))
    }

    private func job(_ job: JobFile, in store: InMemoryStateStore) async throws -> JobFile {
        try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: StatePath.job(Self.repo, epic: job.epic, job: job.id))))
    }

    @Test func retryReassignsJobWaitingForHuman() async throws {
        let (store, waiting) = try await waitingJob(attempts: 2)
        try await retry(waiting, attempt: 2, in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "retry")])
        let retried = try await job(waiting, in: store)
        #expect(retried.state == .assigned)
        #expect(retried.nextRunAt == nil)
        // 当てた試行の番号は変えない（次の試行は 3 番になる）
        #expect(retried.attempts == 2)
        #expect(retried.assignedMac == Self.commander)
    }

    @Test func retryIsRejectedForStaleOrWrongTarget() async throws {
        // 人が見た後に試行が進んだ
        var (store, waiting) = try await waitingJob(attempts: 3)
        try await retry(waiting, attempt: 2, in: store)
        #expect(try await intake(store).processPending() == [.rejected(kind: "retry", reason: "試行の番号が今のジョブと違う（今は 3）")])
        #expect(try await job(waiting, in: store).state == .waitingHuman)

        // 人の対応を待っていない（一時停止中）
        (store, waiting) = try await waitingJob(state: .paused)
        try await retry(waiting, attempt: 1, in: store)
        #expect(try await intake(store).processPending() == [.rejected(kind: "retry", reason: "ジョブは人の対応を待っていない（paused）")])

        // epic をやめた
        (store, waiting) = try await waitingJob(stage: .abandoned)
        try await retry(waiting, attempt: 1, in: store)
        #expect(try await intake(store).processPending() == [.rejected(kind: "retry", reason: "epic はもう終わっている（abandoned）")])
        #expect(try await job(waiting, in: store).state == .waitingHuman)

        // payload に知らない欄がある
        (store, waiting) = try await waitingJob()
        try await retry(waiting, attempt: 1, payload: ["force": .bool(true)], in: store)
        let outcome = try await intake(store).processPending()
        #expect(outcome.count == 1)
        #expect(try await job(waiting, in: store).state == .waitingHuman)
    }

    /// 前の周で戻した後に記録を書く前に止まっても、次の周で同じ意図を受け付け直す
    @Test func redoingRetryIsAccepted() async throws {
        let (store, assigned) = try await waitingJob(state: .assigned)
        try await retry(assigned, attempt: 1, in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "retry")])
        #expect(try await job(assigned, in: store) == assigned)
    }

    // MARK: - やめる

    /// 質問づくりをやめると、epic ごとやめ、epic のほかのジョブも取り消す
    @Test func givingUpBlockingJobAbandonsEpic() async throws {
        let (store, waiting) = try await waitingJob()
        let (_, other) = try await waitingJob(.explain, state: .assigned, epic: try await epic(of: waiting, in: store), in: store)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await epic(of: waiting, in: store).stage == .abandoned)
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await job(other, in: store).state == .canceled)
    }

    /// 人がやめる前に、ほかの理由で取り消されたジョブ（答え直して着手前の確認が取り消された など）では、epic をやめない
    @Test func givingUpCanceledJobDoesNotAbandonEpic() async throws {
        let (store, canceled) = try await waitingJob(.checkReadiness, stage: .asking, state: .canceled)
        try await retry(canceled, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.rejected(kind: "giveUp", reason: "ジョブは人の対応を待っていない（canceled）")])
        #expect(try await epic(of: canceled, in: store).stage == .asking)
    }

    /// 説明をやめると、ジョブだけやめ、質問を回答待ちに戻す
    @Test func givingUpExplanationReopensQuestion() async throws {
        let store = InMemoryStateStore()
        let epic = QuestionJobsTests.epicFile()
        let file = try QuestionFlow.start([QuestionJobsTests.draft("q1")]).questions
        let clarify = QuestionJobsTests.answer("q1", mode: .clarify, note: "保存とは？", intent: 1)
        let clarifying = try QuestionFlow.accept(clarify, epic: epic, questions: file, at: Self.timestamp).questions
        await store.put(StatePath.questions(Self.repo, epic.id), data: try StateFileCoder.encode(clarifying))
        let input: [String: JSONValue] = ["question": .string("q1"), "asked": JSONValue.encoding(QuestionJobsTests.intent(1)) ?? .null]
        let (_, waiting) = try await waitingJob(.explain, input: input, epic: epic, in: store)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await self.epic(of: waiting, in: store).stage == .asking)
        let data = try #require(await store.data(at: StatePath.questions(Self.repo, epic.id)))
        let questions = try StateFileCoder.decode(QuestionsFile.self, from: data)
        let question = try #require(questions.questions.first { $0.id == "q1" })
        #expect(question.state == .open)
        #expect(question.explanations.isEmpty)
    }

    /// ゴールの修正をやめると、ジョブだけやめ、前のゴールのまま開始を待つ
    @Test func givingUpGoalRevisionKeepsEpic() async throws {
        let (store, waiting) = try await waitingJob(.reviseGoal, stage: .awaitingStart)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await epic(of: waiting, in: store).stage == .awaitingStart)
    }
}
