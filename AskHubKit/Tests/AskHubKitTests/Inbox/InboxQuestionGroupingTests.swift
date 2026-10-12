@testable import AskHubKit
import Foundation
import Testing

struct InboxQuestionGroupingTests {
    private func question(_ id: String, kind: InboxSubject.Kind = .discussion, subject nodeID: String) -> InboxQuestion {
        InboxQuestion(
            subject: .fixture(kind: kind, nodeID: nodeID),
            comment: .fixture(nodeID: id, body: #"<!-- ask-hub:question id="q" -->"#),
            marker: QuestionMarker(id: "q")
        )
    }

    @Test func placesDiscussionQuestionsAfterItsOldestQuestion() {
        // 古い順: D_1 の 1 問目、D_2 の 1 問目、D_1 の 2 問目、D_2 の 2 問目、D_1 の 3 問目
        let questions = [
            question("D1-1", subject: "D_1"),
            question("D2-1", subject: "D_2"),
            question("D1-2", subject: "D_1"),
            question("D2-2", subject: "D_2"),
            question("D1-3", subject: "D_1")
        ]
        #expect(InboxQuestion.groupedByDiscussion(questions).map(\.id) == ["D1-1", "D1-2", "D1-3", "D2-1", "D2-2"])
    }

    @Test func keepsPullRequestAsksWhereTheyAre() {
        // PR の ask は同じ PR のものでもまとめず、Discussion のグループの間のそれぞれの位置に残す
        let questions = [
            question("PR1-1", kind: .pullRequest, subject: "PR_1"),
            question("D1-1", subject: "D_1"),
            question("PR1-2", kind: .pullRequest, subject: "PR_1"),
            question("D2-1", subject: "D_2"),
            question("D1-2", subject: "D_1"),
            question("PR2-1", kind: .pullRequest, subject: "PR_2")
        ]
        #expect(InboxQuestion.groupedByDiscussion(questions).map(\.id) == ["PR1-1", "D1-1", "D1-2", "PR1-2", "D2-1", "PR2-1"])
    }

    @Test func keepsAlreadyGroupedQuestions() {
        let questions = [
            question("D1-1", subject: "D_1"),
            question("D1-2", subject: "D_1"),
            question("PR1-1", kind: .pullRequest, subject: "PR_1"),
            question("D2-1", subject: "D_2")
        ]
        #expect(InboxQuestion.groupedByDiscussion(questions) == questions)
        #expect(InboxQuestion.groupedByDiscussion([]).isEmpty)
    }
}
