@testable import AskHubKit
import Foundation
import Testing

struct InboxQuestionTests {
    private let trusted = TrustedAuthors(["mrs1669"])
    private let subject = InboxSubject.fixture()

    @Test func extractsTrustedUnansweredQuestion() {
        let comment = InboxComment.fixture(body: #"<!-- ask-hub:question id="d1-q1" options="A|B" -->本文"#)
        let questions = InboxQuestion.unanswered(
            in: [QuestionThread(comment: comment, replyAuthors: ["someone"])],
            of: subject,
            trustedAuthors: trusted
        )
        #expect(questions == [InboxQuestion(subject: subject, comment: comment, marker: QuestionMarker(id: "d1-q1", options: ["A", "B"]))])
    }

    @Test func skipsAnsweredQuestion() {
        let comment = InboxComment.fixture(body: #"<!-- ask-hub:question id="d1-q1" -->"#)
        let questions = InboxQuestion.unanswered(
            in: [QuestionThread(comment: comment, replyAuthors: [nil, "MRS1669"])],
            of: subject,
            trustedAuthors: trusted
        )
        #expect(questions.isEmpty)
    }

    @Test func ignoresMarkerFromUntrustedOrDeletedAuthor() {
        let body = #"<!-- ask-hub:question id="d1-q1" -->"#
        let questions = InboxQuestion.unanswered(
            in: [
                QuestionThread(comment: .fixture(author: "someone", body: body), replyAuthors: []),
                QuestionThread(comment: .fixture(author: nil, body: body), replyAuthors: [])
            ],
            of: subject,
            trustedAuthors: trusted
        )
        #expect(questions.isEmpty)
    }

    @Test func ignoresCommentWithoutMarker() {
        let questions = InboxQuestion.unanswered(
            in: [QuestionThread(comment: .fixture(body: "ただのコメント"), replyAuthors: [])],
            of: subject,
            trustedAuthors: trusted
        )
        #expect(questions.isEmpty)
    }

    @Test func questionBodyDropsMarker() {
        let question = InboxQuestion(
            subject: subject,
            comment: .fixture(body: "\n<!-- ask-hub:question id=\"d1-q1\" -->\n### Q1. 単位\n送信の上限は？\n"),
            marker: QuestionMarker(id: "d1-q1")
        )
        #expect(question.questionBody == "### Q1. 単位\n送信の上限は？")
    }
}

struct InboxFetcherTests {
    struct StubSource: InboxSource {
        var subjects: [InboxSubject] = []
        var threads: [String: [QuestionThread]] = [:]
        var issues: [InboxIssue] = []
        var waiting: [WaitingDiscussion] = []

        func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
            subjects
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            threads[subject.nodeID] ?? []
        }

        func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
            issues
        }

        func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
            waiting
        }
    }

    @Test func keepsOnlyWaitingDiscussionsByTrustedAuthors() async throws {
        func waiting(_ nodeID: String, number: Int, author: String?) -> WaitingDiscussion {
            var subject = InboxSubject.fixture(kind: .discussion, nodeID: nodeID)
            subject.number = number
            return WaitingDiscussion(subject: subject, lastSeen: nil, author: author)
        }
        let source = StubSource(waiting: [
            waiting("D_2", number: 2, author: "MRS1669"),
            waiting("D_3", number: 3, author: "someone"),
            waiting("D_4", number: 4, author: nil),
            waiting("D_1", number: 1, author: "mrs1669")
        ])
        let discussions = try await InboxFetcher(source: source, trustedAuthors: TrustedAuthors(["mrs1669"]))
            .waitingDiscussions(orgs: ["o"])
        #expect(discussions.map(\.subject.nodeID) == ["D_1", "D_2"])
    }

    @Test func collectsQuestionsAcrossSubjectsOldestFirst() async throws {
        let discussion = InboxSubject.fixture(kind: .discussion, nodeID: "D_1")
        let pullRequest = InboxSubject.fixture(kind: .pullRequest, nodeID: "PR_1")
        let newer = InboxComment.fixture(nodeID: "C_new", body: #"<!-- ask-hub:question id="d1-q1" -->"#, createdAt: 200)
        let older = InboxComment.fixture(nodeID: "C_old", body: #"<!-- ask-hub:question id="pr1-1" -->"#, createdAt: 100)
        let answered = InboxComment.fixture(nodeID: "C_done", body: #"<!-- ask-hub:question id="d1-q2" -->"#, createdAt: 50)
        let source = StubSource(
            subjects: [discussion, pullRequest],
            threads: [
                "D_1": [
                    QuestionThread(comment: newer, replyAuthors: []),
                    QuestionThread(comment: answered, replyAuthors: ["mrs1669"])
                ],
                "PR_1": [QuestionThread(comment: older, replyAuthors: ["coderabbitai"])]
            ]
        )
        let questions = try await InboxFetcher(source: source, trustedAuthors: TrustedAuthors(["mrs1669"]))
            .unansweredQuestions(orgs: ["shilokuma-inc"])
        #expect(questions.map(\.id) == ["C_old", "C_new"])
        #expect(questions.map(\.subject) == [pullRequest, discussion])
    }
}

struct InboxIssueTests {
    @Test func kindFromLabels() {
        #expect(InboxIssue.Kind(labelNames: ["bug", "Needs-Verify"]) == .needsVerify)
        #expect(InboxIssue.Kind(labelNames: ["needs-verify", "decision-log"]) == .decisionLog)
        #expect(InboxIssue.Kind(labelNames: ["bug"]) == nil)
    }

    @Test func fetcherKeepsTrustedIssuesNewestFirst() async throws {
        func issue(_ id: String, author: String?, updatedAt: TimeInterval) -> InboxIssue {
            InboxIssue(
                id: id,
                kind: .needsVerify,
                repository: "o/r",
                number: 1,
                title: id,
                url: URL(string: "https://github.com/o/r/issues/1")!,
                author: author,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
        let source = InboxFetcherTests.StubSource(issues: [
            issue("old", author: "mrs1669", updatedAt: 1),
            issue("spoofed", author: "someone", updatedAt: 3),
            issue("deleted", author: nil, updatedAt: 4),
            issue("new", author: "MRS1669", updatedAt: 2)
        ])
        let issues = try await InboxFetcher(source: source, trustedAuthors: TrustedAuthors(["mrs1669"])).lowPriorityIssues(orgs: ["o"])
        #expect(issues.map(\.id) == ["new", "old"])
    }

    @Test func verifyMarkerIsReadOnlyFromNeedsVerify() {
        func issue(_ kind: InboxIssue.Kind, body: String) -> InboxIssue {
            InboxIssue(
                id: "I_1",
                kind: kind,
                repository: "o/r",
                number: 1,
                title: "タイトル",
                url: URL(string: "https://github.com/o/r/issues/1")!,
                author: "mrs1669",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                body: body
            )
        }
        let marked = #"<!-- ask-hub:verify {"pullRequest":12,"epic":"epic/x"} -->"# + "\n元の PR: #12\n\n確認手順"

        #expect(issue(.needsVerify, body: marked).verifyMarker == VerifyMarker(pullRequest: 12, epic: "epic/x"))
        #expect(issue(.needsVerify, body: "<!-- ask-hub:verify {} -->\n確認手順").verifyMarker == VerifyMarker())
        // 目印の無い既存の Issue では、本文に PR 番号が書かれていても拾わない
        #expect(issue(.needsVerify, body: "元の PR: #12\n\n確認手順").verifyMarker == nil)
        // 仮決め一覧の目印は読まない
        #expect(issue(.decisionLog, body: marked).verifyMarker == nil)
    }
}

extension InboxSubject {
    static func fixture(kind: Kind = .discussion, nodeID: String = "D_1") -> Self {
        Self(
            kind: kind,
            nodeID: nodeID,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 1,
            title: "タイトル",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/1")!
        )
    }
}

extension InboxComment {
    static func fixture(
        nodeID: String = "C_1",
        author: String? = "mrs1669",
        body: String,
        createdAt: TimeInterval = 0
    ) -> Self {
        Self(
            nodeID: nodeID,
            databaseID: 1,
            author: author,
            body: body,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/1#discussioncomment-1")!,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
