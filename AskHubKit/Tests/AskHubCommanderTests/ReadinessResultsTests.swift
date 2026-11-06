import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// Claude を呼ぶ前に決まった処理をしてから、決まった結果を返す（頼んだ後に状態が変わる場合を作る）
struct InterruptingRunner: CommandRunning {
    var interrupt: @Sendable () async throws -> Void
    var result: CommandResult

    func run(_ command: Command) async throws -> CommandResult {
        try await interrupt()
        return result
    }
}

/// 着手前の確認・ゴールの修正・分け方の判断
extension ClaudeJobRunnerTests {
    static func output(_ output: some Encodable) -> CommandResult {
        let data = (try? JSONEncoder().encode(output)) ?? Data()
        return QuestionJobsTests.result(String(bytes: data, encoding: .utf8) ?? "")
    }

    static func goal(decided: [String] = []) -> GoalDraft {
        GoalDraft(
            summary: "ランキングを作る",
            decided: decided.map { GoalFile.Item(question: $0, text: "案1") },
            doneWhen: ["毎日入れ替わる"],
            tasks: [.init(id: "t1", title: "集計を作る")]
        )
    }

    /// 質問の無い依頼を受け付け、質問づくりを終えて、着手前の確認のジョブまで進める
    func checking() async throws -> Requested {
        let given = try await requested()
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        _ = try await runner(given.store, claude: claude).run(given.job)
        let job = try #require(try await jobs(given.epic.id, in: given.store).first { $0.kind == .checkReadiness })
        let epic = try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, given.epic.id), in: given.store))
        return Requested(store: given.store, epic: epic, job: job)
    }

    /// 署名した人の意図を置き、受け付ける
    func submit(
        _ kind: String,
        epic: EpicFile,
        version: String,
        payload: [String: JSONValue],
        in store: InMemoryStateStore
    ) async throws -> [IntakeOutcome] {
        let nonce = ULID.generate(at: Self.now)
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: .init(type: "epic", epic: epic.id),
            targetVersion: version,
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        let intake = IntentIntake(
            context: context(store),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["decideSplit": DecideSplitHandler(), "reviseGoal": ReviseGoalHandler()]
        )
        return try await intake.processPending()
    }

    // MARK: - 着手前の確認

    @Test func readyWritesGoalAndWaitsForStart() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        let claude = ScriptedRunner([Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let goal = try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store))
        #expect(goal.version == 1)
        #expect(goal.tasks.map(\.id) == ["t1"])
        let readiness = try #require(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store))
        #expect(readiness.verdict == .ready)
        #expect(readiness.version == 1)
        #expect(readiness.round == 1)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .awaitingStart)
    }

    @Test func moreQuestionsReturnToAnswers() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        let draft = try Self.decodeDraft(Self.question("q1"))
        let output = CheckReadinessJob.Output(verdict: .moreQuestions, reason: "期間が決まっていない", questions: [draft])
        let claude = ScriptedRunner([Self.output(output)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let questions = try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store))
        #expect(questions.questions.map(\.round) == [2])
        #expect(questions.questions.map(\.state) == [.open])
        #expect(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store)?.verdict == .moreQuestions)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .asking)
    }

    @Test func finishesMoreQuestionsWrittenInEarlierAttempt() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        // 前の試行で追加の質問まで書き、回答に戻す前に止まった
        let empty = QuestionsFile(questions: [])
        let appended = try QuestionFlow.append([try Self.decodeDraft(Self.question("q1"))], round: 2, to: empty).questions
        try await put(appended, at: StatePath.questions(Self.repo, epic.id), in: store)
        let claude = ScriptedRunner([])
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("続きを書いていない"); return }
        #expect(claude.commands.isEmpty)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .asking)
    }

    @Test func recoveryDoesNothingWhenJobWasReplaced() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        // 前の試行で追加の質問まで書いて止まった後に、人が答え直してこのジョブが取り消された
        let draft = try Self.decodeDraft(Self.question("q1"))
        let appended = try QuestionFlow.append([draft], round: 2, to: QuestionsFile(questions: [])).questions
        try await put(appended, at: StatePath.questions(Self.repo, epic.id), in: store)
        var canceled = job
        canceled.state = .canceled
        try await put(canceled, at: StatePath.job(Self.repo, epic: epic.id, job: job.id), in: store)
        guard case .discarded = try await runner(store, claude: ScriptedRunner([])).run(job) else { Issue.record("捨てていない"); return }
        // 回答に戻したり、ほかのジョブを取り消したりしない
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .checking)
    }

    @Test func discardsCheckWhenEpicChangedMeanwhile() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        var reopened = epic
        reopened.stage = .asking
        let path = StatePath.epic(Self.repo, epic.id)
        let data = try StateFileCoder.encode(reopened)
        let ready = Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))
        let claude = InterruptingRunner(interrupt: { await store.put(path, data: data) }, result: ready)
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("捨てていない"); return }
        #expect(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store) == nil)
        #expect(try await read(EpicFile.self, at: path, in: store)?.stage == .asking)
    }

    /// q1 に答えて、着手前の確認のジョブまで進める
    func checkingAfterAnswer() async throws -> Requested {
        let given = try await requested()
        let (store, epic) = (given.store, given.epic)
        let drafts = [QuestionJobsTests.draft("q1")]
        let created = try await answered([answer("q1", epic: epic, nonce: 1)], drafts: drafts, in: store, epic: epic)
        return Requested(store: store, epic: epic, job: try #require(created.first { $0.kind == .checkReadiness }))
    }

    /// Claude を呼んでいる間に、Discussion の写しの id だけを書く
    func copyingWhileRunning(_ given: Requested, result: CommandResult) async throws -> ClaudeJobOutcome {
        let (store, path) = (given.store, StatePath.questions(Self.repo, given.epic.id))
        var copied = try #require(try await read(QuestionsFile.self, at: path, in: store))
        copied.questions[0].comment = "DC_q1"
        let data = try StateFileCoder.encode(copied)
        let claude = InterruptingRunner(interrupt: { await store.put(path, data: data) }, result: result)
        return try await runner(store, claude: claude).run(given.job)
    }

    @Test func checkKeepsResultWhenOnlyCopiesWereWrittenMeanwhile() async throws {
        let given = try await checkingAfterAnswer()
        let (store, epic) = (given.store, given.epic)
        let ready = Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal(decided: ["q1"])))
        let outcome = try await copyingWhileRunning(given, result: ready)
        guard case .written = outcome else { Issue.record("写しの id だけの変化で捨てた（\(outcome)）"); return }
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .awaitingStart)
        let questions = try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store)
        #expect(questions?.questions.first?.comment == "DC_q1")
    }

    @Test func moreQuestionsKeepCopiesWrittenMeanwhile() async throws {
        let given = try await checkingAfterAnswer()
        let (store, epic) = (given.store, given.epic)
        let more = CheckReadinessJob.Output(verdict: .moreQuestions, reason: "期間", questions: [QuestionJobsTests.draft("q2")])
        let outcome = try await copyingWhileRunning(given, result: Self.output(more))
        guard case .written = outcome else { Issue.record("写しの id だけの変化で捨てた（\(outcome)）"); return }
        let questions = try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store))
        #expect(questions.questions.map(\.id) == ["q1", "q2"])
        #expect(questions.questions.map(\.comment) == ["DC_q1", nil])
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .asking)
    }

    // MARK: - 分け方の判断

    /// 大きすぎると返して、分け方の判断の待ちにする
    func awaitingSplit() async throws -> (store: InMemoryStateStore, epic: EpicFile) {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        let parts = [CheckReadinessJob.Part(title: "集計", summary: "日ごとの集計"), .init(title: "画面", summary: "ランキングの画面")]
        let claude = ScriptedRunner([Self.output(CheckReadinessJob.Output(verdict: .tooLarge, reason: "集計と画面が大きい", split: parts))])
        guard case .written = try await runner(store, claude: claude).run(job) else { throw CancellationError() }
        return (store, try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)))
    }

    @Test func tooLargeWaitsForSplitDecision() async throws {
        let (store, epic) = try await awaitingSplit()
        #expect(epic.stage == .awaitingSplit)
        let readiness = try #require(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store))
        #expect(readiness.verdict == .tooLarge)
        #expect(readiness.split.map(\.title) == ["集計", "画面"])
    }

    @Test func splitAbandonsEpic() async throws {
        let (store, epic) = try await awaitingSplit()
        #expect(try await submit("decideSplit", epic: epic, version: "1", payload: ["choice": .string("split")], in: store) == [
            .accepted(kind: "decideSplit")
        ])
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .abandoned)
        #expect(try await jobs(epic.id, in: store).allSatisfy { !JobFile.openStates.contains($0.state) })
    }

    @Test func proceedChecksAgainAndMakesGoal() async throws {
        let (store, epic) = try await awaitingSplit()
        #expect(try await submit("decideSplit", epic: epic, version: "1", payload: ["choice": .string("proceed")], in: store) == [
            .accepted(kind: "decideSplit")
        ])
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .checking)
        // 決めたことは確認の結果に残る（確認のジョブが取り消されても、後の確認に引き継ぐ）
        #expect(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store)?.proceeding == true)
        let job = try #require(try await jobs(epic.id, in: store).first { $0.input?["proceed"] == .bool(true) })
        #expect(job.kind == .checkReadiness)
        // 大きすぎると返したら、同じ会話でゴールを作らせ直す
        let parts = [CheckReadinessJob.Part(title: "集計", summary: "…"), .init(title: "画面", summary: "…")]
        let claude = ScriptedRunner([
            Self.output(CheckReadinessJob.Output(verdict: .tooLarge, reason: "大きい", split: parts)),
            Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "1 つで進める", goal: Self.goal()))
        ])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        #expect(claude.commands.first?.arguments[1].contains("このまま 1 つで進めると決めた") == true)
        #expect(claude.commands.last?.arguments[1].contains("tooLarge は返せない") == true)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .awaitingStart)
        #expect(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store)?.version == 2)
    }

    @Test func proceedingCarriesOverToCheckAfterMoreQuestions() async throws {
        let (store, epic) = try await awaitingSplit()
        _ = try await submit("decideSplit", epic: epic, version: "1", payload: ["choice": .string("proceed")], in: store)
        let proceed = try #require(try await jobs(epic.id, in: store).first { $0.input?["proceed"] == .bool(true) })
        let more = CheckReadinessJob.Output(verdict: .moreQuestions, reason: "期間", questions: [try Self.decodeDraft(Self.question("q1"))])
        guard case .written = try await runner(store, claude: ScriptedRunner([Self.output(more)])).run(proceed) else {
            Issue.record("書けていない")
            return
        }
        // 追加の質問に答えると、印の無い着手前の確認のジョブができる
        let asking = try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store))
        let questionsPath = StatePath.questions(Self.repo, epic.id)
        let questions = try #require(try await read(QuestionsFile.self, at: questionsPath, in: store))
        let answer = answer("q1", epic: epic, nonce: 7)
        let change = try QuestionFlow.accept(answer, epic: asking, questions: questions, at: Timestamp(Self.now))
        try await context(store).perform(change.effects, for: asking, origin: answer.intent)
        try await put(change.questions, at: questionsPath, in: store)
        let check = try #require(try await jobs(epic.id, in: store).first { $0.kind == .checkReadiness && $0.origin == answer.intent })
        #expect(check.input?["proceed"] == nil)
        let ready = CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal(decided: ["q1"]))
        let claude = ScriptedRunner([Self.output(ready)])
        guard case .written = try await runner(store, claude: claude).run(check) else { Issue.record("書けていない"); return }
        // 前の確認の結果から「このまま進める」を引き継ぐ
        #expect(claude.commands.first?.arguments[1].contains("このまま 1 つで進めると決めた") == true)
        #expect(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store)?.proceeding == true)
    }

    @Test func splitDecisionIsRejectedForOldResultOrStage() async throws {
        let (store, epic) = try await awaitingSplit()
        let reason = "着手前の確認の結果が変わった。新しい結果を確かめて選び直す"
        #expect(try await submit("decideSplit", epic: epic, version: "2", payload: ["choice": .string("split")], in: store) == [
            .rejected(kind: "decideSplit", reason: reason)
        ])
        let other = try await checking()
        let proceed: [String: JSONValue] = ["choice": .string("proceed")]
        let outcomes = try await submit("decideSplit", epic: other.epic, version: "1", payload: proceed, in: other.store)
        #expect(outcomes == [.rejected(kind: "decideSplit", reason: "分け方を選べる段階でない（今は checking）")])
    }

    // MARK: - ゴールの修正

    /// ゴールを作り、開始の待ちにする
    func awaitingStart() async throws -> (store: InMemoryStateStore, epic: EpicFile) {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        let claude = ScriptedRunner([Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))])
        guard case .written = try await runner(store, claude: claude).run(job) else { throw CancellationError() }
        return (store, try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)))
    }

    @Test func reviseGoalWritesNextVersionWithNotApplied() async throws {
        let (store, epic) = try await awaitingStart()
        #expect(try await submit("reviseGoal", epic: epic, version: "1", payload: ["instruction": .string("完了の条件を足して")], in: store) == [
            .accepted(kind: "reviseGoal")
        ])
        let job = try #require(try await jobs(epic.id, in: store).first { $0.kind == .reviseGoal })
        var draft = Self.goal()
        draft.doneWhen.append("前日との差が出る")
        let output = ReviseGoalJob.Output(goal: draft, notApplied: ["回答を変える指示は反映しない"])
        let claude = ScriptedRunner([Self.output(output)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let goal = try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store))
        #expect(goal.version == 2)
        #expect(goal.doneWhen == ["毎日入れ替わる", "前日との差が出る"])
        #expect(goal.notApplied == ["回答を変える指示は反映しない"])
        // 書いた後にやり直しても、ゴールの版が変わっているので捨てる
        guard case .discarded = try await runner(store, claude: ScriptedRunner([])).run(job) else { Issue.record("捨てていない"); return }
    }

    @Test func reviseGoalKeepsCopyWrittenMeanwhile() async throws {
        let (store, epic) = try await awaitingStart()
        _ = try await submit("reviseGoal", epic: epic, version: "1", payload: ["instruction": .string("完了の条件を足して")], in: store)
        let job = try #require(try await jobs(epic.id, in: store).first { $0.kind == .reviseGoal })
        let path = StatePath.goal(Self.repo, epic.id)
        var copied = try #require(try await read(GoalFile.self, at: path, in: store))
        copied.comment = "DC_goal"
        let data = try StateFileCoder.encode(copied)
        let output = Self.output(ReviseGoalJob.Output(goal: Self.goal(), notApplied: []))
        let claude = InterruptingRunner(interrupt: { await store.put(path, data: data) }, result: output)
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let goal = try #require(try await read(GoalFile.self, at: path, in: store))
        #expect(goal.version == 2)
        #expect(goal.comment == "DC_goal")
    }
}
