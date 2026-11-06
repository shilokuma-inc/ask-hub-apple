@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import Foundation
import Testing

struct GoalJobsTests {
    typealias Fixture = QuestionJobsTests

    /// q1・q2 に答えた一覧。`round` は q2 の回
    private func answered(round: Int = 1) throws -> QuestionsFile {
        var file = try QuestionFlow.start([Fixture.draft("q1")]).questions
        if round > 1 {
            file = try QuestionFlow.append([Fixture.draft("q2")], round: round, to: file).questions
        } else {
            file = try QuestionFlow.start([Fixture.draft("q1"), Fixture.draft("q2")]).questions
        }
        for (index, id) in ["q1", "q2"].enumerated() {
            let answer = Fixture.answer(id, intent: index + 1)
            file = try QuestionFlow.accept(answer, epic: Fixture.epicFile(), questions: file, at: Fixture.now).questions
        }
        return file
    }

    private func goal(decided: [String] = ["q1", "q2"]) -> GoalDraft {
        GoalDraft(
            summary: "ランキングを作る",
            decided: decided.map { GoalFile.Item(question: $0, text: "案1") },
            doneWhen: ["毎日入れ替わる"],
            tasks: [.init(id: "t1", title: "集計を作る")]
        )
    }

    // MARK: - 着手前の確認

    @Test func readyNeedsValidGoal() throws {
        let job = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered())
        #expect(job.problems(in: .init(verdict: .ready, reason: "そろった", goal: goal())).isEmpty)
        #expect(job.problems(in: .init(verdict: .ready, reason: "そろった")) == ["verdict が ready なのに、goal が無い"])
        #expect(job.problems(in: .init(verdict: .ready, reason: "そろった", goal: goal(decided: ["q1"]))) == [
            "決まったこと（decided）に、回答した質問 q2 が無い"
        ])
        #expect(job.prompt.contains("q1: q1 の題\n回答: 案1"))
    }

    @Test func moreQuestionsAreCheckedAgainstExistingOnes() throws {
        let job = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered())
        #expect(job.nextRound == 2)
        #expect(job.canAskMore)
        #expect(job.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q3", dependsOn: ["q1"])])).isEmpty)
        #expect(job.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q1")])) == ["すでにある質問の id: q1"])
        let empty = CheckReadinessJob.Output(verdict: .moreQuestions, reason: "…", questions: [])
        #expect(job.problems(in: empty) == ["verdict が moreQuestions なのに、questions が無い"])
    }

    @Test func noMoreQuestionsAfterLastRound() throws {
        // 質問は 3 回目の回まで（round が 4 になる前に、人に出す）
        let job = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered(round: 3))
        #expect(!job.canAskMore)
        #expect(job.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q3")])) == [
            "追加の質問はもう出せない。ready か tooLarge にする"
        ])
        #expect(job.problems(in: .init(verdict: .tooLarge, reason: "保存の方式が決めきれない")).isEmpty)
        #expect(job.prompt.contains("追加の質問はもう出せない"))
    }

    @Test func firstQuestionMakingCountsAsRoundOneWithoutQuestions() {
        // 質問が 1 つも無かった依頼でも、追加の質問は 2 回目の回として出す
        let job = CheckReadinessJob(title: "文言", body: "…", questions: QuestionsFile(questions: []))
        #expect(job.nextRound == 2)
        #expect(job.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q1")])).isEmpty)
    }

    @Test func proceedingDisallowsTooLarge() throws {
        let job = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered(), proceeding: true)
        #expect(job.canAskMore)
        #expect(job.prompt.contains("このまま 1 つで進めると決めた"))
        #expect(!job.prompt.contains("verdict を tooLarge にし"))
        let parts = [CheckReadinessJob.Part(title: "集計", summary: "…"), .init(title: "画面", summary: "…")]
        #expect(job.problems(in: .init(verdict: .tooLarge, reason: "大きい", split: parts)) == [
            "人がこのまま 1 つで進めると決めたので、tooLarge は返せない"
        ])
        // 人が決めるべき点は、回が残っていれば追加の質問で人に決めてもらう
        #expect(job.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q3")])).isEmpty)
        #expect(job.problems(in: .init(verdict: .ready, reason: "1 つで進める", goal: goal())).isEmpty)
        // 回を使い切ったら、決めきれない点は仮に決めてゴールに書かせる
        let last = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered(round: 3), proceeding: true)
        #expect(last.prompt.contains("仮に決めたこと"))
        #expect(last.problems(in: .init(verdict: .moreQuestions, reason: "…", questions: [Fixture.draft("q3")])) == [
            "追加の質問はもう出せない。ready にする"
        ])
    }

    @Test func tooLargeNeedsSplitWhileQuestionsRemain() throws {
        let job = CheckReadinessJob(title: "ランキング", body: "…", questions: try answered())
        let parts = [CheckReadinessJob.Part(title: "集計", summary: "…"), .init(title: "画面", summary: "…")]
        #expect(job.problems(in: .init(verdict: .tooLarge, reason: "大きい", split: parts)).isEmpty)
        #expect(job.problems(in: .init(verdict: .tooLarge, reason: "大きい", split: [parts[0]])) == [
            "verdict が tooLarge なのに、split に 2 つ以上の案が無い"
        ])
    }

    // MARK: - ゴールの修正

    @Test func reviseGoalKeepsDecisionsComplete() throws {
        let questions = try answered()
        let current = try GoalFlow.goal(from: goal(), questions: questions, version: 1)
        let job = ReviseGoalJob(goal: current, questions: questions, instruction: "完了の条件に、0 時の入れ替えを足して")
        #expect(job.prompt.contains("完了の条件に、0 時の入れ替えを足して"))
        #expect(job.prompt.contains("要約: ランキングを作る"))
        #expect(job.problems(in: .init(goal: goal(), notApplied: ["q1 を変える指示は、回答を変えて直す"])).isEmpty)
        #expect(!job.problems(in: .init(goal: goal(decided: []))).isEmpty)
    }

    @Test func goalSchemaRequiresWholeGoal() {
        #expect(ReviseGoalJob.outputSchema["required"] == .array([.string("goal"), .string("notApplied")]))
        #expect(CheckReadinessJob.outputSchema["required"] == .array([.string("verdict"), .string("reason")]))
    }
}
