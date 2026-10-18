@testable import AskHubKit
import Foundation
import Testing

/// 最終 PR のコメントから、今の head の第三者レビューと進み具合の目印を読む
struct MergeQueueFinalReviewTests {
    private static let head = "0123456789abcdef0123456789abcdef01234567"
    private static let oldHead = "fedcba9876543210fedcba9876543210fedcba98"

    private func makeQueue(_ http: MockHTTPClient) -> GitHubMergeQueue {
        let client = GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
        return GitHubMergeQueue(client: client, trustedAuthors: TrustedAuthors(["mrs1669"]))
    }

    /// PR の会話のコメント 1 件
    private static func comment(_ author: String?, _ body: String) -> String {
        let authorJSON = author.map { #"{ "login": "\#($0)" }"# } ?? "null"
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{ "author": \#(authorJSON), "body": "\#(escaped)" }"#
    }

    /// PR のコメントの 1 ページ
    private static func comments(_ nodes: [String], hasNextPage: Bool = false, endCursor: String? = nil) -> String {
        let cursorJSON = endCursor.map { #""\#($0)""# } ?? "null"
        let pageInfo = #"{ "hasNextPage": \#(hasNextPage), "endCursor": \#(cursorJSON) }"#
        return #"{ "pageInfo": \#(pageInfo), "nodes": [\#(nodes.joined(separator: ", "))] }"#
    }

    /// 2 ページ目以降のコメントの取得の応答
    private static func commentsPage(_ comments: String) -> String {
        #"{ "data": { "repository": { "pullRequest": { "comments": \#(comments) } } } }"#
    }

    private static func node(number: Int = 1, head: String = head, comments: String?) -> String {
        GitHubMergeQueueTests.node(
            number: number,
            author: "mrs1669",
            mergeable: "MERGEABLE",
            contexts: GitHubMergeQueueTests.contexts([GitHubMergeQueueTests.checkRun("build / build")]),
            head: head,
            comments: comments
        )
    }

    private static func review(_ sha: String, must: Int, may: Int = 0) -> String {
        #"<!-- ralph:third-party-review sha="\#(sha)" must="\#(must)" may="\#(may)" -->"# + "\n## 🔍 コードレビュー（第三者）"
    }

    private static func progress(_ state: String, _ sha: String, attempts: Int = 0) -> String {
        #"<!-- ask-hub:final-review state="\#(state)" sha="\#(sha)" attempts="\#(attempts)" -->"# + "\n第三者レビューの状況"
    }

    @Test func attachesLatestTrustedMarkersForCurrentHead() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                Self.node(comments: Self.comments([
                    Self.comment("mrs1669", Self.review(Self.head, must: 2, may: 1)),
                    Self.comment("mrs1669", Self.progress("reviewing", Self.head, attempts: 1)),
                    // 同じ head の目印が複数あれば最新のもの（大文字の SHA も今の head とみなす）
                    Self.comment("MRS1669", Self.review(Self.head.uppercased(), must: 0, may: 3)),
                    // 信用しない author・削除済みのユーザーの目印は読まない
                    Self.comment("someone", Self.review(Self.head, must: 5)),
                    Self.comment(nil, Self.progress("gave-up", Self.head)),
                    // 前の head の目印は使わない
                    Self.comment("mrs1669", Self.review(Self.oldHead, must: 4)),
                    Self.comment("mrs1669", Self.progress("done", Self.oldHead)),
                    // 目印の無いコメント
                    Self.comment("mrs1669", "LGTM")
                ]))
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.count == 1)
        #expect(pulls[0].thirdPartyReview == ThirdPartyReviewMarker(sha: Self.head, must: 0, may: 3))
        #expect(pulls[0].finalReview == FinalReviewMarker(state: .reviewing, sha: Self.head, attempts: 1))
        // コメントが 1 ページに収まれば取り直さない
        #expect(http.requests.count == 1)
    }

    @Test func attachesCIFixRecordFromTrustedOrchestratorComments() async throws {
        func marker(_ action: CIFixMarker.Action, _ sha: String) -> String {
            "\(FinalPullRequestMarker.orchestrator)\n\(CIFixMarker(action: action, sha: sha).htmlComment ?? "")\n本文"
        }
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                Self.node(comments: Self.comments([
                    // CI の修正の記録は head を問わず読む。取り消した試行は数えない
                    Self.comment("mrs1669", marker(.attempt, Self.oldHead)),
                    Self.comment("mrs1669", marker(.attempt, Self.head)),
                    Self.comment("mrs1669", marker(.cancel, Self.head)),
                    // 信用しない author の目印は読まない
                    Self.comment("someone", marker(.gaveUp, Self.head))
                ]))
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.first?.ciFix == CIFixRecord(attemptedSHAs: [Self.oldHead], gaveUp: false))
    }

    @Test func leavesMarkersNilWithoutMarkersForCurrentHead() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                // 前の head の目印しか無い
                Self.node(number: 1, comments: Self.comments([
                    Self.comment("mrs1669", Self.review(Self.oldHead, must: 0)),
                    Self.comment("mrs1669", Self.progress("done", Self.oldHead))
                ])),
                // 信用しない author の目印しか無い
                Self.node(number: 2, comments: Self.comments([
                    Self.comment("someone", Self.review(Self.head, must: 0)),
                    Self.comment("someone", Self.progress("done", Self.head))
                ])),
                // コメントが無い・comments が返らない
                Self.node(number: 3, comments: Self.comments([])),
                Self.node(number: 4, comments: nil)
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.number) == [1, 2, 3, 4])
        #expect(pulls.allSatisfy { $0.thirdPartyReview == nil && $0.finalReview == nil })
    }

    @Test func fetchesRemainingCommentsUntilLastPage() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                // 1 ページ目には古いレビュー（要修正あり）しか無く、続きがある
                Self.node(number: 7, comments: Self.comments(
                    [Self.comment("mrs1669", Self.review(Self.head, must: 1))], hasNextPage: true, endCursor: "c1"
                ))
            ])),
            .init(status: 200, body: Self.commentsPage(Self.comments(
                [Self.comment("mrs1669", Self.progress("fixing", Self.head, attempts: 1))], hasNextPage: true, endCursor: "c2"
            ))),
            .init(status: 200, body: Self.commentsPage(Self.comments([Self.comment("mrs1669", Self.review(Self.head, must: 0, may: 2))])))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        // 最後のページにある最新のレビューを使う
        #expect(pulls.first?.thirdPartyReview == ThirdPartyReviewMarker(sha: Self.head, must: 0, may: 2))
        #expect(pulls.first?.finalReview == FinalReviewMarker(state: .fixing, sha: Self.head, attempts: 1))
        #expect(http.requests.count == 3)
        let second = try Self.variables(of: http.requests[1])
        #expect(second["owner"] as? String == "o")
        #expect(second["name"] as? String == "r")
        #expect(second["number"] as? Int == 7)
        #expect(second["after"] as? String == "c1")
        let third = try Self.variables(of: http.requests[2])
        #expect(third["after"] as? String == "c2")
    }

    @Test func doesNotFetchCommentsOfUntrustedPullRequests() async throws {
        let untrusted = GitHubMergeQueueTests.node(
            number: 1,
            author: "someone",
            mergeable: "MERGEABLE",
            contexts: nil,
            comments: Self.comments([], hasNextPage: true, endCursor: "c1")
        )
        let http = MockHTTPClient([.init(status: 200, body: GitHubMergeQueueTests.searchPage([untrusted]))])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.isEmpty)
        #expect(http.requests.count == 1)
    }

    @Test func failsWhenNextCommentsPageHasNoCursor() async {
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                Self.node(comments: Self.comments([], hasNextPage: true))
            ]))
        ])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])
        }
    }

    @Test func estimatesWhenHeadWasReceived() async throws {
        let codeRabbit = GitHubMergeQueueTests.status(
            state: "SUCCESS", description: "Review rate limited", createdAt: "2026-10-17T10:00:00Z"
        )
        let http = MockHTTPClient([
            .init(status: 200, body: GitHubMergeQueueTests.searchPage([
                // commit status CodeRabbit の作成時刻を使う
                GitHubMergeQueueTests.node(
                    number: 1,
                    author: "mrs1669",
                    mergeable: "MERGEABLE",
                    contexts: GitHubMergeQueueTests.contexts([codeRabbit]),
                    committedDate: "2026-10-17T09:00:00Z"
                ),
                // CodeRabbit が無ければ head のコミットの日時
                GitHubMergeQueueTests.node(
                    number: 2,
                    author: "mrs1669",
                    mergeable: "MERGEABLE",
                    contexts: GitHubMergeQueueTests.contexts([GitHubMergeQueueTests.checkRun("build / build")]),
                    committedDate: "2026-10-17T09:30:00Z"
                ),
                // どちらも無ければ分からない
                GitHubMergeQueueTests.node(number: 3, author: "mrs1669", mergeable: "MERGEABLE", contexts: nil),
                // PR を開く前のコミットなら、PR の作成時刻から（開いたばかりの PR をすぐレビューしない）
                GitHubMergeQueueTests.node(
                    number: 4,
                    author: "mrs1669",
                    mergeable: "MERGEABLE",
                    contexts: nil,
                    committedDate: "2026-10-16T09:00:00Z",
                    createdAt: "2026-10-17T11:00:00Z"
                )
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        let formatter = ISO8601DateFormatter()
        #expect(pulls.map(\.headSince) == [
            formatter.date(from: "2026-10-17T10:00:00Z"), formatter.date(from: "2026-10-17T09:30:00Z"), nil,
            formatter.date(from: "2026-10-17T11:00:00Z")
        ])
    }

    private static func variables(of request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["variables"] as? [String: Any])
    }
}
