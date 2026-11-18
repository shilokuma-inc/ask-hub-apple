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
        #expect(try await intake(store).processPending() == [.rejected(kind: "retry", reason: "やり直しの形が違う（payload に知らない欄がある）")])
        #expect(try await job(waiting, in: store).state == .waitingHuman)
    }

    /// 直しの上限を超えて、試行の前に人に渡した直し（試行 0）もやり直せる
    @Test(arguments: zip([JobKind.fixTask, .fixFinalPullRequest], [EpicStage.running, .finalizing]))
    func retryReassignsFixHandedOverBeforeAnyAttempt(kind: JobKind, stage: EpicStage) async throws {
        let (store, waiting) = try await waitingJob(kind, stage: stage, attempts: 0)
        try await retry(waiting, attempt: 0, in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "retry")])
        let retried = try await job(waiting, in: store)
        #expect(retried.state == .assigned)
        // 次の試行は 1 番になる
        #expect(retried.attempts == 0)
    }

    /// マージした epic の片付けは、やり直せる（片付けはマージの後に動く）
    @Test func retryReassignsCleanUpOfMergedEpic() async throws {
        let (store, waiting) = try await waitingJob(.cleanUp, stage: .merged)
        try await retry(waiting, attempt: 1, in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "retry")])
        #expect(try await job(waiting, in: store).state == .assigned)
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

    /// 開始した後の epic に残っていた開始の前のジョブをやめても、そのジョブだけやめ、epic とタスクのジョブはそのまま動かす
    @Test(arguments: [EpicStage.running, .finalizing, .reviewing], [JobKind.makeQuestions, .reviseQuestion, .checkReadiness])
    func givingUpPlanningJobOfStartedEpicCancelsOnlyThatJob(stage: EpicStage, kind: JobKind) async throws {
        let (store, waiting) = try await waitingJob(kind, stage: stage)
        let epic = try await epic(of: waiting, in: store)
        let (_, implementing) = try await waitingJob(.implementTask, state: .running, epic: epic, in: store)
        let (_, reviewing) = try await waitingJob(.reviewTask, state: .assigned, epic: epic, in: store)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await self.epic(of: waiting, in: store) == epic)
        #expect(try await job(implementing, in: store) == implementing)
        #expect(try await job(reviewing, in: store) == reviewing)
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

    // MARK: - 実装と最終 PR の段取りのジョブをやめる

    /// 実装と最終 PR の段取りのジョブをやめると、epic ごと取り下げ、ほかのジョブも取り消し、一時停止の印を外す
    /// （開いている子 PR と最終 PR は、周の最後に `AbandonedPullRequests` が閉じる）
    @Test(arguments: [
        (JobKind.prepareWorkspace, EpicStage.running), (.implementTask, .running), (.reviewTask, .running), (.fixTask, .running),
        (.verifyBeforeFinal, .finalizing), (.classifyDecisions, .finalizing), (.openFinalPullRequest, .finalizing),
        (.reviewFinalPullRequest, .finalizing), (.fixFinalPullRequest, .reviewing), (.mergeFinalPullRequest, .reviewing)
    ])
    func givingUpImplementationJobAbandonsStartedEpic(kind: JobKind, stage: EpicStage) async throws {
        let time = Self.timestamp
        let pause = EpicFile.Pause(since: time, origin: .init(keyId: keyID, nonce: .generate(at: Self.now)))
        var started = EpicFile(id: .generate(at: Self.now), repo: Self.repo, title: "ランキング", stage: stage, createdAt: time, updatedAt: time)
        started.mac = Self.commander
        started.pause = pause
        let (store, waiting) = try await waitingJob(kind, epic: started)
        let (_, other) = try await waitingJob(.implementTask, state: .running, epic: started, in: store)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        let abandoned = try await epic(of: waiting, in: store)
        #expect(abandoned.stage == .abandoned)
        #expect(abandoned.pause == nil)
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await job(other, in: store).state == .canceled)
    }

    /// マージした epic の片付けは、ジョブだけやめる（残りは見回りで消える）
    @Test func givingUpCleanUpCancelsOnlyThatJob() async throws {
        let (store, waiting) = try await waitingJob(.cleanUp, stage: .merged)
        try await retry(waiting, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await job(waiting, in: store).state == .canceled)
        #expect(try await epic(of: waiting, in: store).stage == .merged)
    }

    /// 撮影をやめると、撮っていない判断のカードと画面の変化を「スクショ無し（撮影をやめた）」にし、撮影の前のジョブの後に、
    /// 同じ最終 PR と head のレビューを作る（撮影の代わりに段取りの列につなぐ）
    @Test func givingUpScreenshotsReviewsWithoutThem() async throws {
        let time = Self.timestamp
        let head = String(repeating: "c", count: 40)
        let id = ULID.generate(at: Self.now)
        var epic = EpicFile(id: id, repo: Self.repo, title: "ランキング", stage: .finalizing, createdAt: time, updatedAt: time)
        epic.mac = MacName(rawValue: "macbook")
        epic.finalPullRequest = 512
        let shot = DecisionsFile.Screenshots(before: nil, after: nil, head: head, note: "撮った")
        let decisions = DecisionsFile(
            items: [
                .init(id: "d1", task: "t1", visible: true, what: "見出しを短くした", why: "幅", scene: "home"),
                .init(id: "d2", task: "t1", visible: true, what: "色を変えた", why: "読みやすさ", scene: "list", screenshots: shot),
                .init(id: "d3", task: "t1", visible: false, what: "名前を変えた", why: "揃える")
            ],
            screens: [.init(scene: "settings")]
        )
        let store = InMemoryStateStore()
        await store.put(StatePath.decisions(Self.repo, epic.id), data: try StateFileCoder.encode(decisions))
        let (_, open) = try await waitingJob(.openFinalPullRequest, state: .succeeded, epic: epic, in: store)
        let input = PullRequestInput(pullRequest: 512, head: head).jobInput
        var (_, capture) = try await waitingJob(.captureScreenshots, input: input, epic: epic, in: store)
        capture.dependsOn = [open.id]
        await store.put(StatePath.job(Self.repo, epic: epic.id, job: capture.id), data: try StateFileCoder.encode(capture))

        try await retry(capture, attempt: 1, kind: "giveUp", in: store)
        #expect(try await intake(store).processPending() == [.accepted(kind: "giveUp")])
        #expect(try await job(capture, in: store).state == .canceled)
        #expect(try await self.epic(of: capture, in: store).stage == .finalizing)
        let data = try #require(await store.data(at: StatePath.decisions(Self.repo, epic.id)))
        let written = try StateFileCoder.decode(DecisionsFile.self, from: data)
        let skipped = DecisionsFile.Screenshots(head: head, note: "スクショ無し（撮影をやめた）")
        #expect(written.items.map(\.screenshots) == [skipped, shot, nil])
        #expect(written.screens?.map(\.screenshots) == [skipped])

        let jobs = try await jobList(epic, in: store)
        let review = try #require(jobs.first { $0.kind == .reviewFinalPullRequest })
        #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: 512, head: head))
        #expect(review.dependsOn == [open.id])
        #expect(review.assignedMac == Self.commander)
        #expect(review.state == .assigned)
        #expect(FinalChain(jobs: jobs).ordered?.map(\.kind) == [.openFinalPullRequest, .reviewFinalPullRequest])
    }

    private func jobList(_ epic: EpicFile, in store: InMemoryStateStore) async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: epic.id)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }
}
