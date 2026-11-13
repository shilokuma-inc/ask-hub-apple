@testable import AskHubEpics
import AskHubProtocol
import Foundation
import Testing

struct QuestionFlowTests {
    typealias Flow = QuestionFlow

    /// 結果の質問の一覧が、いつも決まりに合っている
    @discardableResult
    private func checked(_ change: Flow.Change, sourceLocation: SourceLocation = #_sourceLocation) -> Flow.Change {
        #expect(change.questions.violations.isEmpty, "\(change.questions.violations)", sourceLocation: sourceLocation)
        return change
    }

    private func accept(_ answer: AnswerIntent, _ file: QuestionsFile, stage: EpicStage = .asking) throws -> Flow.Change {
        checked(try Flow.accept(answer, epic: Fixtures.epic(stage), questions: file, at: Fixtures.now))
    }

    /// q1 → q2 → q3 と依存する質問
    private let chain = [Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"]), Fixtures.draft("q3", dependsOn: ["q2"])]

    /// `chain` を作り、q1 から順に答えて、すべて回答済みにする
    private func answeredChain() throws -> QuestionsFile {
        var file = try Flow.start(chain).questions
        file = try accept(Fixtures.answer("q1", intent: 1), file).questions
        file = try checked(Flow.revise("q2", basis: basis("q2", in: file), outcome: .keep, in: file)).questions
        file = try accept(Fixtures.answer("q2", intent: 2), file).questions
        file = try checked(Flow.revise("q3", basis: basis("q3", in: file), outcome: .keep, in: file)).questions
        return try accept(Fixtures.answer("q3", intent: 3), file).questions
    }

    private func basis(_ id: String, in file: QuestionsFile) -> RevisionBasis {
        Flow.Book(file).basis(of: file.question(id)!)
    }

    // MARK: - 質問を作る

    @Test func startLocksOnlyQuestionsWithDependencies() throws {
        let change = checked(try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"]), Fixtures.draft("q3")]))
        #expect(change.questions.states() == ["q1": .open, "q2": .locked, "q3": .open])
        #expect(change.questions.questions.allSatisfy { $0.round == 1 && $0.version == 1 })
        #expect(change.effects.isEmpty)
    }

    @Test func startWithoutQuestionsGoesToReadinessCheck() throws {
        #expect(try Flow.start([]).effects == [.checkReadiness])
    }

    @Test func startRejectsDraftsThatBreakRules() {
        let cases: [[QuestionDraft]] = [
            [Fixtures.draft("q1", dependsOn: ["q2"]), Fixtures.draft("q2", dependsOn: ["q1"])],
            [Fixtures.draft("q1", dependsOn: ["q9"])],
            [Fixtures.draft("q1"), Fixtures.draft("q1")],
            [Fixtures.draft("../q1")]
        ]
        for drafts in cases {
            #expect(throws: (any Error).self) { try Flow.start(drafts) }
        }
        var draft = Fixtures.draft("q1")
        draft.recommended = "月ごと"
        #expect(throws: Flow.ResultError.invalid(["q1: 推奨が選択肢に無い"])) { try Flow.start([draft]) }
    }

    // MARK: - 回答

    @Test func answerUnlocksDependentForRevision() throws {
        let file = try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"])]).questions
        let change = try accept(Fixtures.answer("q1", note: "夜間は長くてもよい", intent: 1), file)
        let answer = try #require(change.questions.question("q1")?.answer)
        #expect(answer == .init(choice: "日ごと", note: "夜間は長くてもよい", intent: Fixtures.intent(1), at: Fixtures.now))
        #expect(change.questions.states() == ["q1": .answered, "q2": .revising])
        let expected = RevisionBasis(version: 1, dependencies: [.init(id: "q1", version: 1, answer: Fixtures.intent(1))])
        #expect(change.effects == [.revise(question: "q2", basis: expected)])
    }

    @Test func everyQuestionWaitsForPersonAndFreeTextNeedsNoChoice() throws {
        let file = try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2")]).questions
        // 判断はすべて人がする。推奨の選択肢で決めたことにはしないので、答えていない質問があるうちは着手前の確認に進まない
        let first = try accept(Fixtures.answer("q1", intent: 1), file)
        #expect(first.questions.states() == ["q1": .answered, "q2": .open])
        #expect(first.effects.isEmpty)
        let change = try accept(Fixtures.answer("q2", choice: nil, note: "隔週で入れ替える", intent: 2), first.questions)
        #expect(change.questions.question("q2")?.answer?.choice == nil)
        #expect(change.questions.question("q2")?.state == .answered)
        #expect(change.effects == [.checkReadiness])
    }

    @Test func rejectsAnswersThatDoNotApply() throws {
        let file = try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"])]).questions
        let cases: [(answer: AnswerIntent, rejection: Flow.Rejection)] = [
            (Fixtures.answer("q1", choice: "月ごと"), .unknownChoice(question: "q1")),
            (Fixtures.answer("q1", version: 2), .staleVersion(question: "q1", current: 1)),
            (Fixtures.answer("q2"), .notAnswerable(question: "q2", state: .locked)),
            (Fixtures.answer("q9"), .unknownQuestion("q9"))
        ]
        for (answer, rejection) in cases {
            #expect(throws: rejection) { try Flow.accept(answer, epic: Fixtures.epic(), questions: file, at: Fixtures.now) }
            #expect(!rejection.reason.isEmpty)
        }
        for stage in [EpicStage.drafting, .running, .merged] {
            #expect(throws: Flow.Rejection.notAcceptingAnswers(stage)) {
                try Flow.accept(Fixtures.answer("q1"), epic: Fixtures.epic(stage), questions: file, at: Fixtures.now)
            }
        }
        var other = Fixtures.answer("q1")
        other.epic = try #require(ULID(rawValue: "01JCEP1C000000000000000002"))
        #expect(throws: Flow.Rejection.otherEpic) { try Flow.accept(other, epic: Fixtures.epic(), questions: file, at: Fixtures.now) }
    }

    @Test func answerAfterReadinessCheckReopensAndChecksAgain() throws {
        let file = try answeredChain()
        let change = try accept(Fixtures.answer("q3", choice: "週ごと", intent: 4), file, stage: .awaitingStart)
        #expect(change.effects == [.reopen, .checkReadiness])
    }

    // MARK: - 説明

    @Test func clarifyWaitsForExplanationThenReopens() throws {
        let file = try Flow.start([Fixtures.draft("q1")]).questions
        let asking = try accept(Fixtures.answer("q1", .clarify, note: "集計の保存とは？", intent: 1), file)
        #expect(asking.questions.question("q1")?.state == .clarifying)
        #expect(asking.questions.question("q1")?.explanations == [.init(asked: Fixtures.intent(1), note: "集計の保存とは？", at: Fixtures.now)])
        #expect(asking.effects == [.explain(question: "q1", asked: Fixtures.intent(1))])
        #expect(throws: Flow.Rejection.notAnswerable(question: "q1", state: .clarifying)) {
            try Flow.accept(Fixtures.answer("q1", intent: 2), epic: Fixtures.epic(), questions: asking.questions, at: Fixtures.now)
        }

        let explained = checked(try Flow.explain("q1", asked: Fixtures.intent(1), text: "保存は…", rewrite: nil, in: asking.questions))
        #expect(explained.questions.question("q1")?.state == .open)
        #expect(explained.questions.question("q1")?.explanations.last?.text == "保存は…")
        #expect(explained.questions.question("q1")?.version == 1)
        #expect(explained.effects.isEmpty)
    }

    @Test func explanationCanRewriteQuestionAndOldVersionIsRejected() throws {
        let file = try Flow.start([Fixtures.draft("q1")]).questions
        let asking = try accept(Fixtures.answer("q1", .clarify, intent: 1), file).questions
        let rewritten = checked(
            try Flow.explain("q1", asked: Fixtures.intent(1), text: "…", rewrite: Fixtures.rewrite(), in: asking)
        ).questions
        let question = try #require(rewritten.question("q1"))
        #expect(question.version == 2)
        #expect(question.revision == .init(from: 1, reason: "選択肢を分けた", by: .explain))
        #expect(question.options.map(\.label) == ["毎日", "毎週", "毎月"])
        #expect(throws: Flow.Rejection.staleVersion(question: "q1", current: 2)) {
            try Flow.accept(Fixtures.answer("q1", choice: "日ごと", intent: 2), epic: Fixtures.epic(), questions: rewritten, at: Fixtures.now)
        }
        _ = try accept(Fixtures.answer("q1", version: 2, choice: "毎週", intent: 2), rewritten)
    }

    @Test func explanationThatNoLongerAppliesIsDiscarded() throws {
        let file = try Flow.start([Fixtures.draft("q1")]).questions
        let asking = try accept(Fixtures.answer("q1", .clarify, intent: 1), file).questions
        #expect(throws: Flow.ResultError.stale) { try Flow.explain("q1", asked: Fixtures.intent(2), text: "…", rewrite: nil, in: asking) }
        #expect(throws: Flow.ResultError.stale) { try Flow.explain("q1", asked: Fixtures.intent(1), text: "…", rewrite: nil, in: file) }
        #expect(throws: Flow.ResultError.invalid(["説明が空"])) {
            try Flow.explain("q1", asked: Fixtures.intent(1), text: "", rewrite: nil, in: asking)
        }
        #expect(throws: Flow.ResultError.invalid(["書き直した理由が空"])) {
            try Flow.explain("q1", asked: Fixtures.intent(1), text: "…", rewrite: Fixtures.rewrite(""), in: asking)
        }
        #expect(throws: Flow.Rejection.notAnswerable(question: "q1", state: .answered)) {
            let answered = try accept(Fixtures.answer("q1", intent: 3), file).questions
            return try Flow.accept(Fixtures.answer("q1", .clarify, intent: 4), epic: Fixtures.epic(), questions: answered, at: Fixtures.now)
        }
    }

    /// 説明のジョブを人がやめたら、問いを外して回答を待つ状態に戻す。前の説明は残す
    @Test func abandoningExplanationReopensQuestion() throws {
        let file = try Flow.start([Fixtures.draft("q1")]).questions
        let first = try accept(Fixtures.answer("q1", .clarify, note: "保存とは？", intent: 1), file).questions
        let explained = checked(try Flow.explain("q1", asked: Fixtures.intent(1), text: "保存は…", rewrite: nil, in: first)).questions
        let asking = try accept(Fixtures.answer("q1", .clarify, note: "もっと詳しく", intent: 2), explained).questions
        #expect(throws: Flow.ResultError.stale) { try Flow.abandonExplanation("q1", asked: Fixtures.intent(1), in: asking) }

        let abandoned = checked(try Flow.abandonExplanation("q1", asked: Fixtures.intent(2), in: asking))
        let question = try #require(abandoned.questions.question("q1"))
        #expect(question.state == .open)
        #expect(question.explanations.map(\.note) == ["保存とは？"])
        #expect(abandoned.effects.isEmpty)
        // やめた後は、もう一度やめても当てはまらない
        #expect(throws: Flow.ResultError.stale) { try Flow.abandonExplanation("q1", asked: Fixtures.intent(2), in: abandoned.questions) }
        _ = try accept(Fixtures.answer("q1", intent: 3), abandoned.questions)
    }

    // MARK: - 依存とロック

    @Test func changingAnswerRelocksDependentsAndRevisesAgain() throws {
        let file = try answeredChain()
        #expect(file.states() == ["q1": .answered, "q2": .answered, "q3": .answered])
        let change = try accept(Fixtures.answer("q1", choice: "週ごと", intent: 4), file)
        #expect(change.questions.states() == ["q1": .answered, "q2": .revising, "q3": .locked])
        #expect(change.questions.question("q2")?.answer == nil)
        #expect(change.questions.question("q3")?.answer == nil)
        let expected = RevisionBasis(version: 1, dependencies: [.init(id: "q1", version: 1, answer: Fixtures.intent(4))])
        #expect(change.effects == [.revise(question: "q2", basis: expected)])
    }

    /// 同じ選択・同じメモの答え直しは、前の回答の記録（意図）のままにする
    @Test func sameAnswerAgainKeepsDependents() throws {
        let file = try answeredChain()
        let change = try accept(Fixtures.answer("q1", intent: 4), file)
        #expect(change.questions.states() == ["q1": .answered, "q2": .answered, "q3": .answered])
        #expect(change.questions.question("q1")?.answer?.intent == Fixtures.intent(1))
        #expect(change.questions == file)
        #expect(change.effects == [.checkReadiness])
    }

    /// 見直しを頼んだ後に同じ答えがもう一度届いても、頼んだ見直しの結果を書ける（前提の回答の記録が替わらない）
    @Test func sameAnswerWhileRevisingKeepsRevisionBasis() throws {
        var file = try Flow.start(chain).questions
        file = try accept(Fixtures.answer("q1", intent: 1), file).questions
        let requested = basis("q2", in: file)
        let again = try accept(Fixtures.answer("q1", intent: 2), file)
        #expect(again.questions == file)
        #expect(again.effects.isEmpty)
        let revised = checked(try Flow.revise("q2", basis: requested, outcome: .keep, in: again.questions))
        #expect(revised.questions.question("q2")?.state == .open)
    }

    @Test func relockCancelsWorkInProgressAndDropsPendingQuestion() throws {
        var file = try answeredChain()
        // q3 の回答を取り消せないので、q3 を説明待ちにした一覧を作る（q2 を答え直す前の状態）
        file.questions[2].state = .open
        file.questions[2].answer = nil
        file = try accept(Fixtures.answer("q3", .clarify, intent: 5), file).questions
        let change = try accept(Fixtures.answer("q2", choice: "週ごと", intent: 6), file)
        #expect(change.questions.question("q3")?.state == .revising)
        #expect(change.questions.question("q3")?.explanations.isEmpty == true)
        #expect(change.effects.first == .cancel(question: "q3"))
        #expect(change.effects.count == 2)
    }

    // MARK: - 見直し

    @Test func revisionKeepsRewritesOrDropsQuestion() throws {
        var file = try Flow.start(chain).questions
        file = try accept(Fixtures.answer("q1", intent: 1), file).questions
        let basis = basis("q2", in: file)

        let kept = checked(try Flow.revise("q2", basis: basis, outcome: .keep, in: file))
        #expect(kept.questions.question("q2")?.state == .open)
        #expect(kept.questions.question("q2")?.version == 1)
        #expect(kept.effects.isEmpty)

        let rewritten = checked(try Flow.revise("q2", basis: basis, outcome: .rewrite(Fixtures.rewrite("q1 の回答に合わせた")), in: file))
        #expect(rewritten.questions.question("q2")?.version == 2)
        #expect(rewritten.questions.question("q2")?.revision == .init(from: 1, reason: "q1 の回答に合わせた", by: .dependency))

        let dropped = checked(try Flow.revise("q2", basis: basis, outcome: .drop(reason: "日ごとなら週の締めは要らない"), in: file))
        #expect(dropped.questions.states() == ["q1": .answered, "q2": .dropped, "q3": .revising])
        #expect(dropped.questions.question("q2")?.version == 2)
        let expected = RevisionBasis(version: 1, dependencies: [.init(id: "q2", version: 2, answer: nil)])
        #expect(dropped.effects == [.revise(question: "q3", basis: expected)])
        #expect(throws: Flow.ResultError.invalid(["要らない理由が空"])) {
            try Flow.revise("q2", basis: basis, outcome: .drop(reason: ""), in: file)
        }
    }

    @Test func droppingLastQuestionGoesToReadinessCheck() throws {
        var file = try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"])]).questions
        file = try accept(Fixtures.answer("q1", intent: 1), file).questions
        let change = checked(try Flow.revise("q2", basis: basis("q2", in: file), outcome: .drop(reason: "…"), in: file))
        #expect(change.effects == [.checkReadiness])

        // 依存先の回答を変えたら、要らなくなった質問も見直し直す（前の見直しの理由は消す）
        let relocked = try accept(Fixtures.answer("q1", choice: "週ごと", intent: 2), change.questions)
        #expect(relocked.questions.question("q2")?.state == .revising)
        #expect(relocked.questions.question("q2")?.revision == nil)
    }

    @Test func revisionRequestedBeforeAnswerChangedIsDiscarded() throws {
        var file = try Flow.start([Fixtures.draft("q1"), Fixtures.draft("q2", dependsOn: ["q1"])]).questions
        file = try accept(Fixtures.answer("q1", intent: 1), file).questions
        let old = basis("q2", in: file)
        file = try accept(Fixtures.answer("q1", choice: "週ごと", intent: 2), file).questions
        #expect(file.question("q2")?.state == .revising)
        #expect(throws: Flow.ResultError.stale) { try Flow.revise("q2", basis: old, outcome: .keep, in: file) }
        _ = checked(try Flow.revise("q2", basis: basis("q2", in: file), outcome: .keep, in: file))
    }

    // MARK: - 慎重に決めてほしい理由

    @Test func cautionIsCarriedFromDraftAndReplacedByRewrite() throws {
        var draft = Fixtures.draft("q1")
        draft.caution = Caution(kind: .security, reason: "書き出したファイルをほかのアプリから読めるかに関わる")
        let file = checked(try Flow.start([draft])).questions
        #expect(file.question("q1")?.caution == draft.caution)

        // 書き直しの案は中身を丸ごと置き換えるので、理由を付けなければ外れる
        let asking = try accept(Fixtures.answer("q1", .clarify, intent: 1), file).questions
        let plain = checked(try Flow.explain("q1", asked: Fixtures.intent(1), text: "…", rewrite: Fixtures.rewrite(), in: asking)).questions
        #expect(plain.question("q1")?.caution == nil)
        var rewrite = Fixtures.rewrite()
        rewrite.caution = Caution(kind: .irreversible, reason: "書き出した後は消せない")
        let marked = checked(try Flow.explain("q1", asked: Fixtures.intent(1), text: "…", rewrite: rewrite, in: asking)).questions
        #expect(marked.question("q1")?.caution == rewrite.caution)

        draft.caution?.reason = ""
        #expect(throws: Flow.ResultError.invalid(["q1: caution.reason は 1〜500 文字"])) { try Flow.start([draft]) }
    }

    // MARK: - 追加の質問

    @Test func appendAddsQuestionsOfLaterRound() throws {
        let file = try answeredChain()
        let drafts = [Fixtures.draft("q4", dependsOn: ["q1"]), Fixtures.draft("q5", dependsOn: ["q4"])]
        let change = checked(try Flow.append(drafts, round: 2, to: file))
        #expect(change.questions.question("q4")?.state == .open)
        #expect(change.questions.question("q5")?.state == .locked)
        #expect(change.questions.question("q4")?.round == 2)
        #expect(change.effects == [.reopen])

        #expect(throws: Flow.ResultError.invalid(["すでにある質問の id: q1"])) { try Flow.append([Fixtures.draft("q1")], round: 2, to: file) }
        #expect(throws: Flow.ResultError.invalid(["足す質問が無い"])) { try Flow.append([], round: 2, to: file) }
        #expect(throws: Flow.ResultError.invalid(["追加の質問の round は 2 以上"])) { try Flow.append([Fixtures.draft("q4")], round: 1, to: file) }
    }
}
