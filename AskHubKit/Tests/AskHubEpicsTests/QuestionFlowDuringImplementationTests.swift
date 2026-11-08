@testable import AskHubEpics
import AskHubProtocol
import Foundation
import Testing

/// 実装の途中の質問（`docs/renewal/flows.md` の「実装の途中の質問」）
struct QuestionFlowDuringImplementationTests {
    static let asking = ULID(rawValue: "01JCJ0B0000000000000000002")!
    static let asked = TaskOutputReport.Question(
        title: "同点の並び",
        why: "同点のときの並びが決まっていない",
        options: [.init(label: "名前順", effect: "…"), .init(label: "登録順", effect: "…")],
        recommended: "名前順",
        reason: "探しやすい"
    )

    /// 開始する前に答えた q1・q2（q2 は 2 回目の質問づくり）
    static func started() throws -> QuestionsFile {
        var file = try QuestionFlow.start([Fixtures.draft("q1")]).questions
        file = try QuestionFlow.append([Fixtures.draft("q2")], round: 2, to: file).questions
        for (index, id) in ["q1", "q2"].enumerated() {
            file = try QuestionFlow.accept(Fixtures.answer(id, intent: index + 1), epic: Fixtures.epic(), questions: file, at: Fixtures.now)
                .questions
        }
        return file
    }

    @Test func addsQuestionWithNextNumberAndRound() throws {
        let file = try QuestionFlow.ask(Self.asked, job: Self.asking, task: "t2", in: try Self.started())
        let added = try #require(file.question("q3"))
        #expect(added.state == .open)
        #expect(added.round == 3)
        #expect(added.dependsOn.isEmpty)
        #expect(added.job == Self.asking)
        #expect(added.task == "t2")
        #expect(added.recommended == "名前順")
        #expect(file.violations.isEmpty)

        // 同じジョブの質問は 2 度足さない（やり直し）
        #expect(try QuestionFlow.ask(Self.asked, job: Self.asking, task: "t2", in: file) == file)

        // 開始する前の質問が 1 つも無ければ 2 回目。最終 PR の直しの質問はタスクを持たない
        let empty = try QuestionFlow.ask(Self.asked, job: Self.asking, task: nil, in: QuestionsFile(questions: []))
        #expect(empty.question("q1")?.round == 2)
        #expect(empty.question("q1")?.task == nil)
    }

    @Test func refusesQuestionThatBreaksRules() throws {
        var broken = Self.asked
        broken.recommended = "どちらでもない"
        let file = try Self.started()
        #expect(throws: QuestionFlow.ResultError.self) { try QuestionFlow.ask(broken, job: Self.asking, task: "t2", in: file) }
    }

    @Test func answerResumesAskingJobWithoutReopeningPlanning() throws {
        let file = try QuestionFlow.ask(Self.asked, job: Self.asking, task: "t2", in: try Self.started())
        for stage in [EpicStage.running, .finalizing, .reviewing] {
            let change = try QuestionFlow.accept(
                Fixtures.answer("q3", choice: "名前順", note: "同点は ID 順", intent: 5),
                epic: Fixtures.epic(stage),
                questions: file,
                at: Fixtures.now
            )
            let answered = try #require(change.questions.question("q3"))
            #expect(answered.state == .answered)
            #expect(answered.answer?.choice == "名前順")
            #expect(answered.answer?.note == "同点は ID 順")
            // 着手前の確認に戻さず、質問したジョブを再開する
            #expect(change.effects == [.resume(question: "q3", job: Self.asking)])
        }
    }

    @Test func clarifyingAsksExplanationLikeBeforeStart() throws {
        let file = try QuestionFlow.ask(Self.asked, job: Self.asking, task: "t2", in: try Self.started())
        let change = try QuestionFlow.accept(
            Fixtures.answer("q3", .clarify, note: "名前順だと何が困る？", intent: 5), epic: Fixtures.epic(.running), questions: file, at: Fixtures.now
        )
        #expect(change.questions.question("q3")?.state == .clarifying)
        #expect(change.effects == [.explain(question: "q3", asked: Fixtures.intent(5))])
        // 説明を書いたら、また答えを待つ
        let explained = try QuestionFlow.explain("q3", asked: Fixtures.intent(5), text: "…", rewrite: nil, in: change.questions)
        #expect(explained.questions.question("q3")?.state == .open)
        #expect(explained.effects.isEmpty)
    }

    @Test func rejectsAnswersThatCannotResume() throws {
        let file = try QuestionFlow.ask(Self.asked, job: Self.asking, task: "t2", in: try Self.started())
        let running = Fixtures.epic(.running)
        // 開始する前の質問は、開始した後は答え直せない
        #expect(throws: QuestionFlow.Rejection.notAcceptingAnswers(.running)) {
            try QuestionFlow.accept(Fixtures.answer("q1", intent: 5), epic: running, questions: file, at: Fixtures.now)
        }
        #expect(throws: QuestionFlow.Rejection.staleVersion(question: "q3", current: 1)) {
            try QuestionFlow.accept(Fixtures.answer("q3", version: 2, intent: 5), epic: running, questions: file, at: Fixtures.now)
        }
        // 答えたら再開するので、答え直し・説明はできない
        let first = Fixtures.answer("q3", choice: "名前順", intent: 5)
        let answered = try QuestionFlow.accept(first, epic: running, questions: file, at: Fixtures.now).questions
        #expect(throws: QuestionFlow.Rejection.resumed(question: "q3")) {
            try QuestionFlow.accept(Fixtures.answer("q3", choice: "登録順", intent: 6), epic: running, questions: answered, at: Fixtures.now)
        }
        #expect(throws: QuestionFlow.Rejection.resumed(question: "q3")) {
            try QuestionFlow.accept(Fixtures.answer("q3", .clarify, intent: 6), epic: running, questions: answered, at: Fixtures.now)
        }
        // 終わった epic には答えない
        #expect(throws: QuestionFlow.Rejection.notAcceptingAnswers(.merged)) {
            try QuestionFlow.accept(Fixtures.answer("q3", intent: 5), epic: Fixtures.epic(.merged), questions: file, at: Fixtures.now)
        }
    }
}
