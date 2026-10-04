@testable import AskHubKit
import Foundation
import Testing

struct AnswerPosterTests {
    private func makePoster(_ http: MockHTTPClient) -> GitHubAnswerPoster {
        GitHubAnswerPoster(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private func question(_ kind: InboxSubject.Kind, databaseID: Int? = 4_175_818_668, options: [String] = ["A", "B"]) -> InboxQuestion {
        InboxQuestion(
            subject: InboxSubject(
                kind: kind,
                nodeID: kind == .discussion ? "D_1" : "PR_1",
                repository: "shilokuma-inc/ask-hub-apple",
                number: 20,
                title: "T",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/20")!
            ),
            comment: InboxComment(
                nodeID: "DC_1",
                databaseID: databaseID,
                author: "mrs1669",
                body: "<!-- ask-hub:question id=\"q1\" -->",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/20#discussion_r1")!,
                createdAt: Date()
            ),
            marker: QuestionMarker(id: "q1", options: options)
        )
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func repliesToDiscussionCommentWithGraphQL() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "data": { "addDiscussionComment": { "comment": { "url": "https://github.com/o/r/discussions/1#discussioncomment-9" } } } }"#)
        ])
        let url = try await makePoster(http).post(Answer(choice: "A", note: "補足"), to: question(.discussion))

        #expect(url.absoluteString == "https://github.com/o/r/discussions/1#discussioncomment-9")
        let request = try #require(http.requests.first)
        #expect(request.url?.path() == "/graphql")
        let variables = try #require(try body(of: request)["variables"] as? [String: String])
        #expect(variables == ["discussion": "D_1", "replyTo": "DC_1", "body": "回答: A\n補足"])
    }

    @Test func repliesToReviewCommentWithREST() async throws {
        let http = MockHTTPClient([
            .init(status: 201, body: #"{ "id": 5, "html_url": "https://github.com/o/r/pull/20#discussion_r5" }"#)
        ])
        let url = try await makePoster(http).post(Answer(choice: "B"), to: question(.pullRequest))

        #expect(url.absoluteString == "https://github.com/o/r/pull/20#discussion_r5")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/repos/shilokuma-inc/ask-hub-apple/pulls/20/comments/4175818668/replies")
        #expect(try body(of: request)["body"] as? String == "回答: B")
    }

    @Test func rejectsInvalidAnswerWithoutSending() async {
        let http = MockHTTPClient([])
        // 選択肢の無い回答・選択肢に無い値・自由記述が空
        await #expect(throws: AnswerPostingError.invalidAnswer) {
            try await makePoster(http).post(Answer(note: "選ばずに書いた"), to: question(.pullRequest))
        }
        await #expect(throws: AnswerPostingError.invalidAnswer) {
            try await makePoster(http).post(Answer(choice: "C"), to: question(.pullRequest))
        }
        await #expect(throws: AnswerPostingError.invalidAnswer) {
            try await makePoster(http).post(Answer(note: "  "), to: question(.discussion, options: []))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func requiresDatabaseIDForReviewComment() async {
        await #expect(throws: AnswerPostingError.missingCommentID) {
            try await makePoster(MockHTTPClient([])).post(Answer(choice: "A"), to: question(.pullRequest, databaseID: nil))
        }
    }
}
