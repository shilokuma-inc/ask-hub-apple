@testable import AskHubKit
import Foundation
import Testing

struct CodeRabbitThreadsTests {
    private static func comment(_ id: Int?, _ author: String?, _ body: String = "指摘") -> String {
        let databaseID = id.map(String.init) ?? "null"
        let login = author.map { #"{"login":"\#($0)"}"# } ?? "null"
        let anchor = id ?? 0
        return #"""
            {"databaseId":\#(databaseID),"url":"https://github.com/o/r/pull/50#discussion_r\#(anchor)",\#
            "createdAt":"2026-10-17T00:00:00Z","body":"\#(body)","author":\#(login)}
            """#
    }

    private static func thread(
        _ id: String,
        resolved: Bool = false,
        line: String = "12",
        comments: [String],
        hasNext: Bool = false,
        cursor: String = "null"
    ) -> String {
        #"""
        {"id":"\#(id)","isResolved":\#(resolved),"isOutdated":false,"path":"A.swift","line":\#(line),\#
        "comments":{"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":\#(cursor)},"nodes":[\#(comments.joined(separator: ","))]}}
        """#
    }

    private static func threadsPage(_ threads: [String], hasNext: Bool = false, cursor: String = "null") -> MockHTTPClient.Response {
        let body = #"""
            {"data":{"node":{"reviewThreads":{"pageInfo":{"hasNextPage":\#(hasNext),"endCursor":\#(cursor)},\#
            "nodes":[\#(threads.joined(separator: ","))]}}}}
            """#
        return .init(status: 200, body: body)
    }

    private static func fetcher(_ http: MockHTTPClient) -> GitHubCodeRabbitThreads {
        GitHubCodeRabbitThreads(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    @Test func returnsOnlyUnresolvedThreadsStartedByCodeRabbit() async throws {
        let http = MockHTTPClient([
            Self.threadsPage([
                Self.thread("T1", comments: [Self.comment(1, "coderabbitai"), Self.comment(2, "mrs1669", "対応します")]),
                Self.thread("T2", resolved: true, comments: [Self.comment(3, "coderabbitai")]),
                Self.thread("T3", comments: [Self.comment(4, "someone")]),
                Self.thread("T4", line: "null", comments: [Self.comment(5, "coderabbitai[bot]")]),
                Self.thread("T5", comments: [Self.comment(nil, nil)])
            ])
        ])

        let threads = try await Self.fetcher(http).unresolvedCodeRabbitThreads(of: .fixture())

        #expect(threads.map(\.id) == ["T1", "T4"])
        #expect(threads[0].finding.id == 1)
        #expect(threads[0].finding.url.absoluteString == "https://github.com/o/r/pull/50#discussion_r1")
        #expect(threads[0].replies.map(\.author) == ["mrs1669"])
        #expect(threads[0].path == "A.swift")
        #expect(threads[0].line == 12)
        #expect(threads[1].line == nil)
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        let sent = String(bytes: try #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(sent.contains(#""id":"PR_50""#))
    }

    @Test func followsThreadPagesAndCommentPagesToTheEnd() async throws {
        let http = MockHTTPClient([
            Self.threadsPage(
                [Self.thread("T1", comments: [Self.comment(1, "coderabbitai")], hasNext: true, cursor: #""C1""#)],
                hasNext: true,
                cursor: #""P1""#
            ),
            Self.threadsPage([Self.thread("T2", comments: [Self.comment(3, "coderabbitai")])]),
            // スレッドを最後まで読んでから、続きのあるスレッドのコメントを読む
            .init(status: 200, body: #"""
                {"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(Self.comment(2, "mrs1669"))]}}}}
                """#)
        ])

        let threads = try await Self.fetcher(http).unresolvedCodeRabbitThreads(of: .fixture())

        #expect(threads.map(\.id) == ["T1", "T2"])
        #expect(threads[0].replies.map(\.id) == [2])
        let bodies = http.requests.map { $0.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? "" }
        #expect(bodies.count == 3)
        #expect(bodies[1].contains(#""after":"P1""#))
        #expect(bodies[2].contains(#""id":"T1""#))
        #expect(bodies[2].contains(#""after":"C1""#))
    }

    @Test func waitsAndRetriesWhenRateLimited() async throws {
        let http = MockHTTPClient([
            .init(status: 429, body: "{}", headers: ["Retry-After": "5"]),
            Self.threadsPage([Self.thread("T1", comments: [Self.comment(1, "coderabbitai")])])
        ])
        let threads = try await Self.fetcher(http).unresolvedCodeRabbitThreads(of: .fixture())
        #expect(threads.map(\.id) == ["T1"])
        #expect(http.requests.count == 2)
    }

    @Test func returnsNothingWhenPullRequestIsMissing() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{"data":{"node":null}}"#)])
        #expect(try await Self.fetcher(http).unresolvedCodeRabbitThreads(of: .fixture()).isEmpty)
    }

    @Test func recognizesCodeRabbitLogins() {
        #expect(CodeRabbitReviewThread.isCodeRabbit("coderabbitai"))
        #expect(CodeRabbitReviewThread.isCodeRabbit("coderabbitai[bot]"))
        #expect(!CodeRabbitReviewThread.isCodeRabbit("mrs1669"))
        #expect(!CodeRabbitReviewThread.isCodeRabbit(nil))
    }
}
