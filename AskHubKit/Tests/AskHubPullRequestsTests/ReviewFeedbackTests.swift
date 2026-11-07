@testable import AskHubPullRequests
import Foundation
import Testing

struct ReviewFeedbackTests {
    private let trusted = TrustedAuthors(["coderabbitai[bot]", "MRS1669"])

    // MARK: - 応答の形

    private static func comment(_ id: Int, _ login: String, _ typename: String = "Bot", body: String? = nil) -> [String: Any] {
        [
            "databaseId": id,
            "body": body ?? "コメント \(id)",
            "url": "https://github.com/shilokuma-inc/ask-hub-apple/pull/7#discussion_r\(id)",
            "createdAt": "2026-11-07T01:00:00Z",
            "author": ["__typename": typename, "login": login]
        ]
    }

    private static func page(_ nodes: [[String: Any]], next: String? = nil) -> [String: Any] {
        ["pageInfo": ["hasNextPage": next != nil, "endCursor": next.map { $0 as Any } ?? NSNull()], "nodes": nodes]
    }

    private static func thread(
        _ id: String,
        resolved: Bool = false,
        comments: [[String: Any]],
        nextComments: String? = nil
    ) -> [String: Any] {
        [
            "id": id, "isResolved": resolved, "isOutdated": false, "path": "AskHub/App.swift", "line": 12,
            "comments": page(comments, next: nextComments)
        ]
    }

    private static func threads(_ threads: [[String: Any]], next: String? = nil) -> String {
        Fixture.json(["data": ["repository": ["pullRequest": ["reviewThreads": page(threads, next: next)]]]])
    }

    private static func review(
        _ id: Int,
        _ login: String,
        state: String = "COMMENTED",
        body: String = "Actionable comments posted: 1"
    ) -> [String: Any] {
        [
            "id": id, "user": ["login": login, "type": login.hasSuffix("[bot]") ? "Bot" : "User"], "body": body, "state": state,
            "commit_id": Fixture.sha, "submitted_at": "2026-11-07T02:00:00Z",
            "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/pull/7#pullrequestreview-\(id)"
        ]
    }

    // MARK: - 行コメントのスレッド

    @Test func readsOnlyUnresolvedThreadsStartedByTrustedAuthors() async throws {
        let transport = StubTransport([
            .json(200, Self.threads([
                // 信用する bot の指摘。信用しない人の返信は除く
                Self.thread("A", comments: [
                    Self.comment(1, "coderabbitai"), Self.comment(2, "mallory", "User"), Self.comment(3, "coderabbitai")
                ]),
                // 解決済み
                Self.thread("B", resolved: true, comments: [Self.comment(4, "coderabbitai")]),
                // 信用しない人が始めたスレッドは、信用する bot が返信していても読まない
                Self.thread("C", comments: [Self.comment(5, "mallory", "User"), Self.comment(6, "coderabbitai")]),
                // bot と同じ名前の人のアカウントは信用しない
                Self.thread("D", comments: [Self.comment(7, "coderabbitai", "User")]),
                // 消えたアカウント・Mannequin は信用しない
                Self.thread("E", comments: [Self.comment(8, "mrs1669", "Mannequin")])
            ], next: "cursor-1")),
            .json(200, Self.threads([Self.thread("F", comments: [Self.comment(9, "mrs1669", "User")])]))
        ])
        let threads = try await Fixture.client(transport).unresolvedThreads(number: 7, trusted: trusted)
        #expect(threads.map(\.id) == ["A", "F"])
        #expect(threads.first?.comments.map(\.id) == [1, 3])
        #expect(threads.first?.comments.first == ReviewComment(
            id: 1,
            author: "coderabbitai[bot]",
            body: "コメント 1",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/7#discussion_r1"),
            createdAt: Date(timeIntervalSince1970: 1_794_013_200)
        ))
        #expect(threads.first?.path == "AskHub/App.swift")
        #expect(threads.first?.line == 12)
        #expect(threads.last?.comments.map(\.author) == ["mrs1669"])

        let requests = transport.requests
        #expect(requests.map { Fixture.path($0) } == ["/graphql", "/graphql"])
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        let first = try #require(Fixture.body(requests.first)["variables"] as? [String: Any])
        #expect(first["owner"] as? String == "shilokuma-inc")
        #expect(first["name"] as? String == "ask-hub-apple")
        #expect(first["number"] as? Int == 7)
        #expect(first["after"] == nil)
        let second = try #require(Fixture.body(requests.last)["variables"] as? [String: Any])
        #expect(second["after"] as? String == "cursor-1")
    }

    @Test func readsRemainingCommentsOfLongThread() async throws {
        let rest = Self.page([Self.comment(3, "coderabbitai"), Self.comment(4, "mallory", "User")])
        let first = Self.thread("A", comments: [Self.comment(1, "coderabbitai"), Self.comment(2, "coderabbitai")], nextComments: "c-2")
        let transport = StubTransport([
            .json(200, Self.threads([first])),
            .json(200, Fixture.json(["data": ["node": ["comments": rest]]]))
        ])
        let threads = try await Fixture.client(transport).unresolvedThreads(number: 7, trusted: trusted)
        #expect(threads.first?.comments.map(\.id) == [1, 2, 3])
        let variables = try #require(Fixture.body(transport.requests.last)["variables"] as? [String: Any])
        #expect(variables["id"] as? String == "A")
        #expect(variables["after"] as? String == "c-2")
    }

    @Test func missingPullRequestIsNotFound() async throws {
        let body = #"{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve"}]}"#
        let transport = StubTransport([.json(200, body)])
        await #expect(throws: PullRequestError.notFound) {
            try await Fixture.client(transport).unresolvedThreads(number: 7, trusted: trusted)
        }
    }

    @Test func graphQLRateLimitWaitsUntilReset() async throws {
        let body = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        let headers = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(Int(Fixture.now.timeIntervalSince1970) + 120)"]
        let transport = StubTransport([.json(200, body, headers: headers)])
        await #expect(throws: PullRequestError.rateLimited(retryAfter: .seconds(121))) {
            try await Fixture.client(transport).unresolvedThreads(number: 7, trusted: trusted)
        }
    }

    // MARK: - レビューの本文

    @Test func readsOnlyTrustedReviewBodiesFollowingPages() async throws {
        let next = "https://api.github.com/repositories/1/pulls/7/reviews?page=2"
        let firstPage = [
            Self.review(1, "coderabbitai[bot]"),
            Self.review(2, "mallory"),
            Self.review(3, "coderabbitai[bot]", body: "  \n"),
            Self.review(4, "coderabbitai[bot]", state: "PENDING"),
            Self.review(5, "coderabbitai[bot]", state: "DISMISSED")
        ]
        let transport = StubTransport([
            .json(200, Fixture.json(firstPage), headers: Fixture.link(next: next)),
            .json(200, Fixture.json([Self.review(6, "mrs1669", state: "CHANGES_REQUESTED", body: "直してください")]))
        ])
        let reviews = try await Fixture.client(transport).reviewBodies(number: 7, trusted: trusted)
        #expect(reviews.map(\.id) == [1, 6])
        #expect(reviews.first == ReviewBody(
            id: 1,
            author: "coderabbitai[bot]",
            state: "COMMENTED",
            body: "Actionable comments posted: 1",
            commitID: Fixture.sha,
            submittedAt: Date(timeIntervalSince1970: 1_794_016_800),
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/7#pullrequestreview-1")
        ))
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/pulls/7/reviews")
        #expect(Fixture.query(transport.requests.first) == ["per_page": "100"])
        #expect(transport.requests.last?.url?.absoluteString == next)
    }

    @Test func readsThreadsAndReviewBodiesTogether() async throws {
        let transport = StubTransport([
            .json(200, Self.threads([Self.thread("A", comments: [Self.comment(1, "coderabbitai")])])),
            .json(200, Fixture.json([Self.review(2, "coderabbitai[bot]")]))
        ])
        let feedback = try await Fixture.client(transport).reviewFeedback(number: 7, trusted: trusted)
        #expect(feedback.threads.map(\.id) == ["A"])
        #expect(feedback.reviews.map(\.id) == [2])
    }

    @Test func trustedAuthorsCompareRESTAndGraphQLForms() {
        let trusted = TrustedAuthors(["coderabbitai[bot]", "Alice"])
        #expect(trusted.contains(restLogin: "CodeRabbitAI[bot]", type: "Bot"))
        #expect(trusted.contains(restLogin: "alice", type: "User"))
        #expect(!trusted.contains(restLogin: "coderabbitai", type: "User"))
        #expect(!trusted.contains(restLogin: "alice", type: "Organization"))
        #expect(trusted.contains(graphQLLogin: "coderabbitai", typename: "Bot"))
        #expect(!trusted.contains(graphQLLogin: "coderabbitai", typename: "User"))
        #expect(trusted.contains(graphQLLogin: "ALICE", typename: "User"))
        #expect(!trusted.contains(graphQLLogin: "alice", typename: "Mannequin"))
    }
}
