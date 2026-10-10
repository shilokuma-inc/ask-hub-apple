@testable import AskHubKit
import Foundation
import Testing

struct GitHubInboxSourceTests {
    private func makeSource(_ http: MockHTTPClient) -> GitHubInboxSource {
        GitHubInboxSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    /// リクエストの GraphQL の変数
    private func variables(of request: URLRequest) throws -> [String: String?] {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(object["variables"] as? [String: Any])
        return variables.mapValues { $0 as? String }
    }

    private static func page(hasNext: Bool, cursor: String?) -> String {
        #"{ "hasNextPage": \#(hasNext), "endCursor": \#(cursor.map { "\"\($0)\"" } ?? "null") }"#
    }

    private static func comment(id: String, author: String?, body: String = "本文", createdAt: String = "2026-10-04T00:00:00Z") -> String {
        let author = author.map { #"{ "login": "\#($0)" }"# } ?? "null"
        return #"""
            "id": "\#(id)", "databaseId": 10, "url": "https://github.com/o/r/pull/1#c-\#(id)",
            "createdAt": "\#(createdAt)", "body": "\#(body)", "author": \#(author)
            """#
    }

    // MARK: - 検索

    @Test func searchesDiscussionsAndPullRequestsAcrossPages() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": \#(Self.page(hasNext: true, cursor: "S1")), "nodes": [
                  { "id": "D_1", "number": 1, "title": "質問", "url": "https://github.com/o/r/discussions/1",
                    "closed": false, "repository": { "nameWithOwner": "o/r" }, "author": { "login": "mrs1669" },
                    "labels": { "nodes": [{ "name": "needs-answer" }, null, { "name": "manual-loop" }] } },
                  {}
                ] } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": \#(Self.page(hasNext: false, cursor: "S2")), "nodes": [
                  { "id": "D_2", "number": 2, "title": "閉じた", "url": "https://github.com/o/r/discussions/2",
                    "closed": true, "repository": { "nameWithOwner": "o/r" } },
                  null
                ] } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [
                  { "id": "PR_3", "number": 3, "title": "PR", "url": "https://github.com/o/r2/pull/3",
                    "closed": false, "repository": { "nameWithOwner": "o/r2" } }
                ] } } }
                """#)
        ])
        let subjects = try await makeSource(http).subjectsNeedingAnswer(orgs: ["shilokuma-inc"])

        let discussionURL = try #require(URL(string: "https://github.com/o/r/discussions/1"))
        let pullRequestURL = try #require(URL(string: "https://github.com/o/r2/pull/3"))
        #expect(subjects == [
            InboxSubject(
                kind: .discussion,
                nodeID: "D_1",
                repository: "o/r",
                number: 1,
                title: "質問",
                url: discussionURL,
                author: "mrs1669",
                labels: ["needs-answer", "manual-loop"]
            ),
            InboxSubject(kind: .pullRequest, nodeID: "PR_3", repository: "o/r2", number: 3, title: "PR", url: pullRequestURL)
        ])
        let requests = http.requests
        #expect(requests.count == 3)
        #expect(try variables(of: requests[0]) == ["query": "org:shilokuma-inc label:needs-answer is:open", "after": nil])
        #expect(try variables(of: requests[1]) == ["query": "org:shilokuma-inc label:needs-answer is:open", "after": "S1"])
        #expect(try variables(of: requests[2]) == ["query": "org:shilokuma-inc label:needs-answer is:pr is:open", "after": nil])
    }

    @Test func searchesLowPriorityIssuesWithOneQuery() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [
                  { "id": "I_9", "number": 9, "title": "仮決め一覧", "url": "https://github.com/o/r/issues/9",
                    "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "2026-10-04T01:00:00Z", "body": "- [ ] #1 既定値",
                    "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" },
                    "labels": { "nodes": [{ "name": "decision-log" }] } },
                  { "id": "I_10", "number": 10, "title": "ラベルが外れた", "url": "https://github.com/o/r/issues/10",
                    "createdAt": "2026-10-01T00:00:00Z", "updatedAt": "2026-10-04T01:00:00Z", "body": "",
                    "author": null, "repository": { "nameWithOwner": "o/r" },
                    "labels": { "nodes": [] } },
                  { "id": "I_11", "number": 11, "title": "【CHORE】実機確認: 通知", "url": "https://github.com/o/r/issues/11",
                    "createdAt": "2026-10-02T00:00:00Z", "updatedAt": "2026-10-03T00:00:00Z",
                    "body": "<!-- ask-hub:verify {\"epic\":\"epic/x\",\"pullRequest\":5} -->\n確認手順",
                    "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" },
                    "labels": { "nodes": [{ "name": "needs-verify" }] } },
                  {}
                ] } } }
                """#)
        ])
        let issues = try await makeSource(http).lowPriorityIssues(orgs: ["shilokuma-inc"])

        #expect(issues.map(\.id) == ["I_9", "I_11"])
        let decisionLog = try #require(issues.first)
        #expect(decisionLog.kind == .decisionLog)
        #expect(decisionLog.author == "mrs1669")
        #expect(decisionLog.createdAt == (try Date("2026-10-01T00:00:00Z", strategy: .iso8601)))
        #expect(decisionLog.updatedAt == (try Date("2026-10-04T01:00:00Z", strategy: .iso8601)))
        #expect(decisionLog.body == "- [ ] #1 既定値")
        #expect(decisionLog.verifyMarker == nil)
        let needsVerify = try #require(issues.last)
        #expect(needsVerify.kind == .needsVerify)
        #expect(needsVerify.body == "<!-- ask-hub:verify {\"epic\":\"epic/x\",\"pullRequest\":5} -->\n確認手順")
        #expect(needsVerify.verifyMarker == VerifyMarker(pullRequest: 5, epic: "epic/x"))
        #expect(try variables(of: http.requests[0]) == [
            "query": "org:shilokuma-inc is:issue is:open label:decision-log,needs-verify",
            "after": nil
        ])
    }

    @Test func searchesAllOrganizationsWithOneQuery() async throws {
        let empty = #"{ "data": { "search": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [] } } }"#
        let http = MockHTTPClient([.init(status: 200, body: empty), .init(status: 200, body: empty)])

        _ = try await makeSource(http).subjectsNeedingAnswer(orgs: ["shilokuma-inc", "BeaconFun4"])

        // org: を並べると OR で検索されるので、organization が増えても検索の回数は変わらない
        #expect(try http.requests.map { try variables(of: $0)["query"] } == [
            "org:shilokuma-inc org:BeaconFun4 label:needs-answer is:open",
            "org:shilokuma-inc org:BeaconFun4 label:needs-answer is:pr is:open"
        ])
    }

    @Test func doesNotSearchWithoutOrganizations() async throws {
        let http = MockHTTPClient([])
        let source = makeSource(http)

        // 修飾子なしで GitHub 全体を検索しない
        #expect(try await source.subjectsNeedingAnswer(orgs: []).isEmpty)
        #expect(try await source.lowPriorityIssues(orgs: []).isEmpty)
        #expect(try await source.waitingDiscussions(orgs: []).isEmpty)
        #expect(http.requests.isEmpty)
    }

    // MARK: - Discussion

    @Test func collectsDiscussionCommentsAndAllReplies() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "node": { "comments": { "pageInfo": \#(Self.page(hasNext: true, cursor: "C1")), "nodes": [
                  { \#(Self.comment(id: "DC_1", author: "mrs1669")),
                    "replies": { "pageInfo": \#(Self.page(hasNext: true, cursor: "R1")), "nodes": [
                      { "author": { "login": "someone" } }, { "author": null }
                    ] } }
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "node": { "comments": { "pageInfo": \#(Self.page(hasNext: false, cursor: "C2")), "nodes": [
                  { \#(Self.comment(id: "DC_2", author: nil)),
                    "replies": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [] } }
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "node": { "replies": { "pageInfo": \#(Self.page(hasNext: false, cursor: "R2")), "nodes": [
                  { "author": { "login": "mrs1669" } }
                ] } } } }
                """#)
        ])
        let threads = try await makeSource(http).questionThreads(of: .fixture(kind: .discussion, nodeID: "D_1"))

        #expect(threads.map(\.comment.nodeID) == ["DC_1", "DC_2"])
        #expect(threads.map(\.comment.author) == ["mrs1669", nil])
        #expect(threads.map(\.replyAuthors) == [["someone", nil, "mrs1669"], []])
        let requests = http.requests
        #expect(try variables(of: requests[0]) == ["id": "D_1", "after": nil])
        #expect(try variables(of: requests[1]) == ["id": "D_1", "after": "C1"])
        #expect(try variables(of: requests[2]) == ["id": "DC_1", "after": "R1"])
    }

    @Test func deletedDiscussionHasNoThreads() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "data": { "node": null } }"#)])
        let threads = try await makeSource(http).questionThreads(of: .fixture(kind: .discussion))
        #expect(threads.isEmpty)
    }

    // MARK: - PR

    @Test func treatsFirstReviewCommentAsQuestionAndRestAsReplies() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "node": { "reviewThreads": { "pageInfo": \#(Self.page(hasNext: false, cursor: "T1")), "nodes": [
                  { "id": "RT_1", "comments": { "pageInfo": \#(Self.page(hasNext: true, cursor: "K1")), "nodes": [
                    { \#(Self.comment(id: "RC_1", author: "mrs1669")) },
                    { \#(Self.comment(id: "RC_2", author: "coderabbitai")) }
                  ] } },
                  { "id": "RT_2", "comments": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [] } },
                  { "id": "RT_3", "comments": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [
                    { \#(Self.comment(id: "RC_4", author: "mrs1669")) }
                  ] } }
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "node": { "comments": { "pageInfo": \#(Self.page(hasNext: false, cursor: "K2")), "nodes": [
                  { \#(Self.comment(id: "RC_3", author: "mrs1669")) }
                ] } } } }
                """#)
        ])
        let threads = try await makeSource(http).questionThreads(of: .fixture(kind: .pullRequest, nodeID: "PR_1"))

        #expect(threads.map(\.comment.nodeID) == ["RC_1", "RC_4"])
        #expect(threads.map(\.replyAuthors) == [["coderabbitai", "mrs1669"], []])
        #expect(threads.first?.comment.databaseID == 10)
        let requests = http.requests
        #expect(try variables(of: requests[0]) == ["id": "PR_1", "after": nil])
        #expect(try variables(of: requests[1]) == ["id": "RT_1", "after": "K1"])
    }

    @Test func nextPageWithoutCursorIsInvalid() async {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "node": { "reviewThreads": { "pageInfo": \#(Self.page(hasNext: false, cursor: nil)), "nodes": [
                  { "id": "RT_1", "comments": { "pageInfo": \#(Self.page(hasNext: true, cursor: nil)), "nodes": [] } }
                ] } } } }
                """#)
        ])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeSource(http).questionThreads(of: .fixture(kind: .pullRequest))
        }
    }
}
