import AskHubClaude
@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 司令塔の、実装の途中の質問（質問を足す・答えるまで次のジョブを作らない・答えで再開のジョブを作る・説明を書く）
struct TaskFlowQuestionTests {
    static let repo = EpicHandlersTests.repo
    static let laptop = EpicHandlersTests.laptop
    static let commander = EpicHandlersTests.commander
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let origin = IntentReference(keyId: keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!)
    static let asked = TaskOutputReport(
        summary: "同点の並びを決めてほしい",
        question: .init(
            title: "同点の並び",
            why: "同点のときの並びが決まっていない",
            options: [.init(label: "名前順", effect: "…"), .init(label: "登録順", effect: "…")],
            recommended: "名前順",
            reason: "探しやすい"
        )
    )

    let store = InMemoryStateStore()
    var context: CommanderContext { CommanderContext(store: store, mac: Self.commander) { Self.now } }

    static func sha(_ character: Character) -> String {
        String(repeating: character, count: 40)
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func read<File: StateFile>(_ type: File.Type, at path: String) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    private func jobs() async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: Self.epicID)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    private func epic() async throws -> EpicFile {
        try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, Self.epicID)))
    }

    private func questions() async throws -> QuestionsFile {
        try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, Self.epicID)))
    }

    private func advance() async throws -> TaskFlow.Advanced {
        await TaskFlow(context: context).advance(epics: [try await epic()], jobs: try await jobs())
    }

    /// 開始した epic（ゴールは t1 → t2、開始する前に答えた q1）と、成功した作業場所の用意
    private func started(stage: EpicStage = .running) async throws {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID,
            repo: Self.repo,
            title: "ランキング",
            stage: stage,
            mac: Self.laptop,
            branch: "askhub/\(Self.epicID)",
            goalVersion: 1,
            createdAt: time,
            updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let tasks: [GoalFile.Task] = [.init(id: "t1", title: "集計を作る"), .init(id: "t2", title: "画面を作る", dependsOn: ["t1"])]
        try await put(GoalFile(version: 1, summary: "ランキングを作る", doneWhen: ["…"], tasks: tasks), at: StatePath.goal(Self.repo, Self.epicID))
        var questions = try QuestionFlow.start([QuestionJobsTests.draft("q1")]).questions
        let answer = QuestionJobsTests.answer("q1", intent: 1)
        questions = try QuestionFlow.accept(answer, epic: QuestionJobsTests.epicFile(), questions: questions, at: time).questions
        try await put(questions, at: StatePath.questions(Self.repo, Self.epicID))
        let spec = JobSpec(kind: .prepareWorkspace, mac: Self.laptop, needs: .init(claude: false, build: false))
        let prepare = context.job(spec, for: epic, origin: Self.origin, seed: "")
        try await put(prepare, at: StatePath.job(Self.repo, epic: Self.epicID, job: prepare.id))
        try await succeed(prepare, outputs: .init(commit: Self.sha("0"), branch: "askhub/\(Self.epicID)"))
    }

    /// ジョブを成功にし、成功した試行を書く
    @discardableResult
    private func succeed(
        _ job: JobFile,
        outputs: AttemptFile.Outputs,
        mac: MacName = TaskFlowQuestionTests.laptop
    ) async throws -> JobFile {
        var job = job
        job.attempts += 1
        job.state = .succeeded
        let time = Timestamp(Self.now)
        let attempt = AttemptFile(
            job: job.id,
            number: job.attempts,
            mac: mac,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: outputs,
            claude: .init(model: "claude-opus-5-5", session: "s-ask")
        )
        try await put(attempt, at: StatePath.attempt(Self.repo, epic: Self.epicID, job: job.id, number: job.attempts))
        try await put(job, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id))
        return job
    }

    /// 人の回答（`answer`）を受け付ける
    private func answer(_ question: String, mode: String = "answer", choice: String? = "名前順", nonce: Int) async throws -> IntentDecision {
        var payload: [String: JSONValue] = ["mode": .string(mode), "note": .string(mode == "answer" ? "同点は ID 順" : "名前順だと何が困る？")]
        if let choice, mode == "answer" { payload["choice"] = .string(choice) }
        let envelope = IntentEnvelope(
            kind: "answer",
            repo: Self.repo,
            target: .init(type: "question", epic: Self.epicID, id: question),
            targetVersion: "1",
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: Self.nonce(nonce),
            keyId: Self.keyID
        )
        return try await AnswerHandler().handle(envelope, in: context)
    }

    /// 子 PR を出した実装・直しの結果
    static func pushed(_ head: String, summary: String) -> AttemptFile.Outputs {
        .init(pullRequest: 41, commit: head, branch: "askhub/E-t1", report: .init(summary: summary))
    }

    static func nonce(_ number: Int) -> ULID {
        ULID(rawValue: "01JCN0NCE" + String(format: "%017d", number))!
    }

    // MARK: - タスクの実装・直し

    @Test func implementationQuestionWaitsForAnswerThenResumesSameJob() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        #expect(implement.kind == .implementTask)
        // 実装が質問で終えた（PR も push した head も無い）
        try await succeed(implement, outputs: .init(branch: "askhub/E-t1", report: Self.asked))
        var step = try await advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.contains { $0.contains("答えを待つ") })
        let added = try #require(try await questions().questions.first { $0.id == "q2" })
        #expect(added.state == .open)
        #expect(added.job == implement.id)
        #expect(added.task == "t1")
        #expect(added.round == 2)
        #expect(added.title == "同点の並び")
        // 答えるまで、レビューも次のタスクも作らない（同じ質問を 2 度足さない）
        step = try await advance()
        #expect(step.created.isEmpty)
        #expect(try await jobs().count == 2)
        #expect(try await questions().questions.count == 2)

        // 答えると、質問したジョブと同じ種類の再開のジョブを作る
        #expect(try await answer("q2", nonce: 7) == .accept)
        let resumed = try #require(try await jobs().first { $0.dependsOn == [implement.id] })
        #expect(resumed.kind == .implementTask)
        #expect(resumed.task == "t1")
        #expect(resumed.input(as: ImplementTaskInput.self)?.question == "q2")
        #expect(resumed.origin == IntentReference(keyId: Self.keyID, nonce: Self.nonce(7)))
        #expect(resumed.assignedMac == Self.laptop)
        #expect(resumed.needs == implement.needs)
        #expect(resumed.state == .assigned)
        let answered = try #require(try await questions().questions.first { $0.id == "q2" })
        #expect(answered.state == .answered)
        #expect(answered.answer?.note == "同点は ID 順")
        // epic は実装のまま（着手前の確認に戻さない）
        #expect(try await epic().stage == .running)
        #expect(try await advance().created.isEmpty)

        // 再開したジョブが子 PR を出したら、いつもどおりレビューに進む
        try await succeed(resumed, outputs: Self.pushed(Self.sha("a"), summary: "作った"))
        let review = try #require(try await advance().created.first)
        #expect(review.kind == .reviewTask)
        #expect(review.dependsOn == [resumed.id])
        #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: 41, head: Self.sha("a")))
    }

    @Test func resumesOnMacOfAskingAttemptAndRecreatesMissingJob() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        let other = MacName(rawValue: "macbook-b")!
        try await succeed(implement, outputs: .init(branch: "askhub/E-t1", report: Self.asked), mac: other)
        _ = try await advance()
        // 答えを書いた後、再開のジョブを作る前に止まった（ふつうは回答の受け付けで作る）
        var file = try await questions()
        let intent = IntentReference(keyId: Self.keyID, nonce: Self.nonce(7))
        file.questions[1].state = .answered
        file.questions[1].answer = .init(choice: "名前順", intent: intent, at: Timestamp(Self.now))
        try await put(file, at: StatePath.questions(Self.repo, Self.epicID))

        let step = try await advance()
        let resumed = try #require(step.created.first)
        #expect(resumed.dependsOn == [implement.id])
        #expect(resumed.origin == intent)
        // 手元の変更と会話は、質問した試行の Mac にある
        #expect(resumed.assignedMac == other)
        // 同じ答えの意図を処理し直しても、回答の受け付けで作るものと同じ id なので、2 つにならない
        #expect(try await answer("q2", nonce: 7) == .accept)
        #expect(try await jobs().filter { $0.dependsOn == [implement.id] }.count == 1)
        // 答え直しは断る（もう再開している）
        #expect(try await answer("q2", choice: "登録順", nonce: 9) == .reject(QuestionFlow.Rejection.resumed(question: "q2").reason))
    }

    @Test func fixQuestionResumesWithoutCountingAnotherFixRound() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        try await succeed(implement, outputs: Self.pushed(Self.sha("a"), summary: "作った"))
        let review = try #require(try await advance().created.first)
        try await succeed(review, outputs: .init(pullRequest: 41, commit: Self.sha("a"), verdict: .fixCI, findings: "落ちた"))
        let fix = try #require(try await advance().created.first)
        #expect(fix.kind == .fixTask)
        try await succeed(fix, outputs: .init(pullRequest: 41, branch: "askhub/E-t1", report: Self.asked))
        #expect(try await advance().created.isEmpty)
        #expect(try await answer("q2", nonce: 7) == .accept)
        let resumed = try #require(try await jobs().first { $0.dependsOn == [fix.id] })
        #expect(resumed.kind == .fixTask)
        #expect(resumed.input(as: FixTaskInput.self) == FixTaskInput(pullRequest: 41, head: Self.sha("a"), reason: .ci, question: "q2"))

        // 再開した直しのレビューがまた直す判定でも、再開した直しは直しの回に数えない（2 回目の直し）
        try await succeed(resumed, outputs: Self.pushed(Self.sha("b"), summary: "直した"))
        let again = try #require(try await advance().created.first)
        try await succeed(again, outputs: .init(pullRequest: 41, commit: Self.sha("b"), verdict: .fixReview, findings: "直す"))
        let second = try #require(try await advance().created.first)
        #expect(second.kind == .fixTask)
        #expect(second.state == .assigned)
        #expect(second.id == context.job(
            JobSpec(kind: .fixTask, mac: Self.laptop, needs: second.needs),
            for: try await epic(),
            origin: Self.origin,
            seed: "\(again.id)/2"
        ).id)
    }

    @Test func notifiesQuestionWhileRunning() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        try await succeed(implement, outputs: .init(branch: "askhub/E-t1", report: Self.asked))
        _ = try await advance()
        // 開始する前の q1（答えた）は知らせず、実装の途中の q2 だけを知らせる
        let blockers = try await BlockerScan(context: context, macOfflineAfter: .seconds(3_600)).scan(epics: [try await epic()], jobs: [])
        #expect(blockers.map(\.key) == ["question/\(Self.repo)/\(Self.epicID)/q2/1/0"])
    }

    // MARK: - 説明

    @Test func explainsQuestionDuringImplementationWithoutDiscarding() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        try await succeed(implement, outputs: .init(branch: "askhub/E-t1", report: Self.asked))
        _ = try await advance()
        #expect(try await answer("q2", mode: "clarify", nonce: 8) == .accept)
        #expect(try await questions().questions.last?.state == .clarifying)
        let explain = try #require(try await jobs().first { $0.kind == .explain })
        // 説明を待つ間も、実装は止めて待つ
        #expect(try await advance().created.isEmpty)

        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"text":"名前順なら一覧で探しやすい。","rewrite":null}"#)])
        let runner = ClaudeJobRunner(
            context: context,
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
            workspace: FixedWorkspace(directory: FileManager.default.temporaryDirectory.appendingPathComponent("TaskFlowQuestionTests")),
            verifier: IntentVerifier(publicKeys: [:])
        )
        // 開始した epic でも、実装の途中の質問の説明は捨てない
        guard case .written = try await runner.run(explain) else { Issue.record("書けていない"); return }
        let explained = try #require(try await questions().questions.last)
        #expect(explained.state == .open)
        #expect(explained.explanations.map(\.text) == ["名前順なら一覧で探しやすい。"])

        // 開始する前の質問の説明は、今までどおり開始した epic では捨てる
        let input: [String: JSONValue] = ["question": .string("q1"), "asked": JSONValue.encoding(Self.origin) ?? .null]
        let planning = context.claudeJob(.explain, for: try await epic(), origin: Self.origin, seed: "q1", input: input)
        guard case .discarded = try await runner.run(planning) else { Issue.record("捨てていない"); return }
    }

    // MARK: - 最終 PR の直し

    @Test func finalFixResumptionIsNotCountedAndFindsOriginalHumanIntent() {
        let decision = IntentReference(keyId: Self.keyID, nonce: Self.nonce(3))
        let answered = IntentReference(keyId: Self.keyID, nonce: Self.nonce(4))
        func job(_ id: String, _ kind: JobKind, input: (any JobInput)?, origin: IntentReference, after parent: JobFile?) -> JobFile {
            JobFile(
                id: ULID(rawValue: "01JCJ0C00000000000000000" + id)!,
                kind: kind,
                repo: Self.repo,
                epic: Self.epicID,
                assignedMac: Self.commander,
                needs: .init(claude: true, build: kind == .fixFinalPullRequest),
                dependsOn: parent.map { [$0.id] } ?? [],
                state: .succeeded,
                input: input?.jobInput,
                origin: origin,
                createdAt: Timestamp(Self.now),
                updatedAt: Timestamp(Self.now)
            )
        }
        let pull = PullRequestInput(pullRequest: 512, head: Self.sha("a"))
        let input = { (reason: FixTaskInput.Reason, question: String?) in
            FixTaskInput(pullRequest: 512, head: pull.head, reason: reason, question: question)
        }
        let review = job("01", .reviewFinalPullRequest, input: pull, origin: Self.origin, after: nil)
        let fix = job("02", .fixFinalPullRequest, input: input(.ci, nil), origin: Self.origin, after: review)
        let resumed = job("03", .fixFinalPullRequest, input: input(.ci, "q2"), origin: answered, after: fix)
        #expect(FinalChain(jobs: [review, fix, resumed]).automaticFixes == 1)

        let human = job("04", .fixFinalPullRequest, input: input(.human, nil), origin: decision, after: review)
        let humanResumed = job("05", .fixFinalPullRequest, input: input(.human, "q3"), origin: answered, after: human)
        // 判断のカードを答え待ちに戻すときは、質問する前の直しの元（判断のカードへの答え）で探す
        #expect(TaskFlow.original(of: humanResumed, in: [review, human, humanResumed]).origin == decision)
        #expect(TaskFlow.original(of: human, in: [review, human, humanResumed]).origin == decision)
    }
}
