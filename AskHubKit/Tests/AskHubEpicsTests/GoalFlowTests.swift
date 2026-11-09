@testable import AskHubEpics
import AskHubProtocol
import Foundation
import Testing

struct GoalFlowTests {
    /// q1・q2 に答え、q3 は見直しで要らなくなった一覧
    private func settled() throws -> QuestionsFile {
        var file = try QuestionFlow.start([Fixtures.draft("q1"), Fixtures.draft("q2"), Fixtures.draft("q3", dependsOn: ["q1"])]).questions
        let first = try QuestionFlow.accept(Fixtures.answer("q1", intent: 1), epic: Fixtures.epic(), questions: file, at: Fixtures.now)
        file = first.questions
        guard case let .revise(_, basis)? = first.effects.first else { throw CancellationError() }
        file = try QuestionFlow.revise("q3", basis: basis, outcome: .drop(reason: "日ごとなら要らない"), in: file).questions
        return try QuestionFlow.accept(Fixtures.answer("q2", intent: 2), epic: Fixtures.epic(), questions: file, at: Fixtures.now).questions
    }

    private func draft(decided: [String] = ["q1", "q2"], links: [String] = ["https://appstoreconnect.apple.com/"]) -> GoalDraft {
        GoalDraft(
            summary: "ランキングを日ごとに入れ替える",
            decided: decided.map { GoalFile.Item(question: $0, text: "\($0) に決まった") },
            outOfScope: ["週ごとの集計"],
            doneWhen: ["毎日 0 時に入れ替わる"],
            tasks: [.init(id: "t1", title: "集計を作る"), .init(id: "t2", title: "課金の画面", dependsOn: ["t1", "h1"])],
            humanTasks: [.init(id: "h1", title: "課金のアイテムを作る", why: "Web でしかできない", steps: ["…"], links: links)]
        )
    }

    @Test func locksTasksThatWaitForHumanTasks() throws {
        let goal = try GoalFlow.goal(from: draft(), questions: settled(), version: 3, comment: "DC_kwDO")
        #expect(goal.version == 3)
        #expect(goal.tasks.map(\.state) == [.pending, .locked])
        #expect(goal.humanTasks.map(\.state) == [.pending])
        #expect(goal.comment == "DC_kwDO")
        #expect(goal.violations.isEmpty)
    }

    @Test func requiresEveryAnsweredQuestionOnce() throws {
        let questions = try settled()
        #expect(throws: QuestionFlow.ResultError.invalid(["決まったこと（decided）に、回答した質問 q2 が無い"])) {
            try GoalFlow.goal(from: draft(decided: ["q1"]), questions: questions, version: 1)
        }
        // 要らなくなった質問は、決まったことに入れない
        #expect(throws: QuestionFlow.ResultError.invalid(["決まったこと（decided）の q3 は、回答した質問ではない"])) {
            try GoalFlow.goal(from: draft(decided: ["q1", "q2", "q3"]), questions: questions, version: 1)
        }
        #expect(throws: QuestionFlow.ResultError.invalid(["決まったこと（decided）で q1 が重なっている"])) {
            try GoalFlow.goal(from: draft(decided: ["q1", "q1", "q2"]), questions: questions, version: 1)
        }
    }

    @Test func rejectsLinksThatAreNotHTTPS() throws {
        #expect(throws: QuestionFlow.ResultError.invalid(["h1: リンク http://example.com は https でない"])) {
            try GoalFlow.goal(from: draft(links: ["http://example.com"]), questions: settled(), version: 1)
        }
    }

    @Test func reportsFileRules() throws {
        var broken = draft()
        broken.tasks.append(.init(id: "t3", title: "", dependsOn: ["t9"]))
        #expect(throws: (any Error).self) { try GoalFlow.goal(from: broken, questions: settled(), version: 1) }
    }
}
