@testable import AskHubKit
import Foundation
import Testing

struct GitHubDecisionLogCommentsTests {
    private func makeFetcher(_ http: MockHTTPClient) -> GitHubDecisionLogComments {
        GitHubDecisionLogComments(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private static func issue(_ kind: InboxIssue.Kind = .decisionLog) -> InboxIssue {
        InboxIssue(
            id: "I_355",
            kind: kind,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 355,
            title: "【CHORE】epic/in-app-decision-verify の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/355")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func comment(id: Int, login: String?, body: String?, createdAt: String) -> String {
        let user = login.map { #"{ "login": "\#($0)" }"# } ?? "null"
        let text = body.map { #""\#($0)""# } ?? "null"
        return #"{ "id": \#(id), "user": \#(user), "body": \#(text), "created_at": "\#(createdAt)", "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/issues/355#issuecomment-\#(id)" }"#
    }

    @Test func followsAllPagesAndSortsByCreation() async throws {
        let next = "https://api.github.com/repositories/1/issues/355/comments?per_page=100&page=2"
        let http = MockHTTPClient([
            .init(
                status: 200,
                body: "[\(Self.comment(id: 30, login: "mrs1669", body: "B", createdAt: "2026-10-11T00:02:00Z"))]",
                headers: ["Link": "<\(next)>; rel=\"next\""]
            ),
            .init(
                status: 200,
                body: """
                    [\(Self.comment(id: 20, login: nil, body: nil, createdAt: "2026-10-11T00:01:00Z")),
                     \(Self.comment(id: 10, login: "mrs1669", body: "A", createdAt: "2026-10-11T00:01:00Z"))]
                    """
            )
        ])
        let comments = try await makeFetcher(http).comments(of: Self.issue())

        #expect(http.requests.map { $0.url?.absoluteString } == [
            "https://api.github.com/repos/shilokuma-inc/ask-hub-apple/issues/355/comments?per_page=100",
            next
        ])
        // 作成順、同時刻は id 順
        #expect(comments.map(\.id) == [10, 20, 30])
        #expect(comments[1].author == nil)
        #expect(comments[1].body.isEmpty)
        #expect(comments[0].createdAt == Date(timeIntervalSince1970: 1_791_676_860))
        #expect(comments[2].url == URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/355#issuecomment-30"))
    }

    @Test func refusesOtherIssues() async {
        let http = MockHTTPClient([])
        await #expect(throws: DecisionLogCommentsError.notDecisionLog) {
            try await makeFetcher(http).comments(of: Self.issue(.needsVerify))
        }
        #expect(http.requests.isEmpty)
    }
}
