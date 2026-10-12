@testable import AskHubKit
import Foundation
import os
import Testing

/// 状態用の Issue の本文とループごとのコメントから行を作る（新しい形と古い形）
struct LoopStatusRowCommentsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])

    private func loop(
        _ state: LoopStatusReport.State, writer: LoopStatusReport.Writer = .orchestrator, discussion: Int?
    ) -> LoopStatusReport {
        LoopStatusReport(state: state, writer: writer, epic: discussion.map { "epic/d\($0)" }, discussion: discussion, checkedAt: now)
    }

    private func comment(_ id: Int, author: String? = "mrs1669", _ report: LoopStatusReport) -> LoopStatusComment {
        LoopStatusComment(id: id, author: author, updatedAt: now, body: report.issueBody)
    }

    private func issue(
        _ number: Int, author: String? = "mrs1669", updatedMinutesAgo: Double = 0, body: String, comments: [LoopStatusComment] = []
    ) -> LoopStatusIssue {
        LoopStatusIssue(
            number: number,
            url: URL(string: "https://github.com/o/r/issues/\(number)")!,
            author: author,
            updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60),
            body: body,
            comments: comments
        )
    }

    private func row(_ issues: [LoopStatusIssue]) -> LoopStatusRow? {
        let heartbeat = OrchestratorHeartbeat.description(at: now)
        let repository = LoopStatusRepository(repository: "o/r", heartbeatDescription: heartbeat, issues: issues)
        return LoopStatusRow.rows(from: [repository], trustedAuthors: trusted).first
    }

    @Test func readsLoopsFromRepositoryBodyAndComments() throws {
        let automatic = loop(.running, discussion: 12)
        let manual = loop(.waitingForAnswer, writer: .manual, discussion: 30)
        let body = RepositoryStatusReport(checkedAt: now).marker
        let spam = comment(13, author: "someone", loop(.gaveUp, discussion: 99))
        let result = try #require(row([issue(1, body: body, comments: [comment(11, manual), comment(12, automatic), spam])]))

        // コメントは信用する author のものだけを読み、ループごとに持つ
        #expect(result.board?.loops.map(\.report) == [automatic, manual])
        #expect(result.board?.repository == RepositoryStatusReport(checkedAt: now))
        // 1 行に出すのは、今までの本文と同じく自動ループ
        #expect(result.report == automatic)
        #expect(result.issueURL == URL(string: "https://github.com/o/r/issues/1"))
    }

    @Test func keepsSingleRowLikeBefore() throws {
        // 古い形の本文（手動ループ）は、今までどおり本文の状態を出す
        let manual = loop(.running, writer: .manual, discussion: 30)
        #expect(row([issue(1, body: manual.issueBody)])?.report == manual)

        // 同じ Discussion のコメントのほうが新しければ、そちら
        var newer = manual
        newer.state = .waitingForAnswer
        newer.checkedAt = now.addingTimeInterval(60)
        #expect(row([issue(1, body: manual.issueBody, comments: [comment(11, newer)])])?.report == newer)

        // 自動ループのコメントが無ければ、最初のループ
        let body = RepositoryStatusReport(checkedAt: now).marker
        #expect(row([issue(1, body: body, comments: [comment(11, manual)])])?.report == manual)

        // ループが 1 つも無ければ、リポジトリ全体の状態から「ループなし」（上限で待機中ならその状態）を作る
        #expect(row([issue(1, body: body)])?.report == LoopStatusReport(state: .noLoop, checkedAt: now))
        let limit = now.addingTimeInterval(3600)
        let limited = RepositoryStatusReport(usageLimitedUntil: limit, checkedAt: now).marker
        #expect(row([issue(1, body: limited)])?.report == LoopStatusReport(state: .usageLimited, usageLimitedUntil: limit, checkedAt: now))

        // 目印を読めない本文（人が編集したなど）でも、コメントは読む
        let unreadable = try #require(row([issue(1, body: "人が書き換えた本文", comments: [comment(11, manual)])]))
        #expect(unreadable.board?.body == .unreadable)
        #expect(unreadable.report == manual)
    }

    @Test func showsNewestLoopEvenWhenFinishedLoopCommentRemains() {
        // 終わったループ（#5）のコメントが残っていても、今のループ（#12）を出す（Discussion の番号の順ではなく確認時刻で選ぶ）
        var finished = loop(.gaveUp, discussion: 5)
        finished.checkedAt = now.addingTimeInterval(-3600)
        let current = loop(.running, discussion: 12)
        let body = RepositoryStatusReport(checkedAt: now).marker
        #expect(row([issue(1, body: body, comments: [comment(11, finished), comment(12, current)])])?.report == current)

        // 自動ループが無ければ、手動ループのうち最も新しく確かめたもの
        var older = loop(.running, writer: .manual, discussion: 20)
        older.checkedAt = now.addingTimeInterval(-600)
        let newer = loop(.waitingForAnswer, writer: .manual, discussion: 30)
        #expect(row([issue(1, body: body, comments: [comment(11, older), comment(12, newer)])])?.report == newer)
    }

    @Test func choosesNewestTrustedIssueWhoseBodyIsReadable() {
        let issues = [
            issue(1, updatedMinutesAgo: 30, body: RepositoryStatusReport(checkedAt: now).marker),
            issue(2, updatedMinutesAgo: 1, body: "人が書いた本文"),
            issue(3, author: "someone", updatedMinutesAgo: 0, body: RepositoryStatusReport(checkedAt: now).marker),
            issue(4, updatedMinutesAgo: 10, body: loop(.running, discussion: 12).issueBody)
        ]
        // 新しい形も古い形も、目印を読めるもののうち最も新しく更新されたもの
        #expect(LoopStatusRow.statusIssue(in: issues, trustedAuthors: trusted)?.number == 4)
        // 読めるものが無ければ、信用する author の最も新しいもの
        #expect(LoopStatusRow.statusIssue(in: [issues[1], issues[2]], trustedAuthors: trusted)?.number == 2)
        #expect(LoopStatusRow.statusIssue(in: [issues[2]], trustedAuthors: trusted) == nil)
    }

    @Test func fetcherReadsCommentsOnlyOfTrustedIssueToUse() async throws {
        final class Source: LoopStatusSource {
            let requested = OSAllocatedUnfairLock<[String]>(initialState: [])
            let repositories: [LoopStatusRepository]
            let comments: [Int: [LoopStatusComment]]

            init(repositories: [LoopStatusRepository], comments: [Int: [LoopStatusComment]]) {
                self.repositories = repositories
                self.comments = comments
            }

            func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
                repositories
            }

            func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment] {
                requested.withLock { $0.append("\(repository)#\(number)") }
                return comments[number] ?? []
            }
        }
        let automatic = loop(.running, discussion: 12)
        let body = RepositoryStatusReport(checkedAt: now).marker
        let source = Source(
            repositories: [
                LoopStatusRepository(repository: "o/r", heartbeatDescription: nil, issues: [
                    issue(5, author: "someone", body: body),
                    issue(1, updatedMinutesAgo: 5, body: body)
                ]),
                // 状態用の Issue が無いリポジトリには問い合わせない
                LoopStatusRepository(repository: "o/s", heartbeatDescription: OrchestratorHeartbeat.description(at: now), issues: [])
            ],
            comments: [1: [comment(11, automatic)], 5: [comment(51, loop(.gaveUp, discussion: 12))]]
        )

        let rows = try await LoopStatusFetcher(source: source, trustedAuthors: trusted).rows(orgs: ["o"])

        #expect(source.requested.withLock { $0 } == ["o/r#1"])
        #expect(rows.first?.report == automatic)
        #expect(rows.map(\.repository) == ["o/r", "o/s"])
    }

}

struct GitHubLoopStatusSourceCommentsTests {
    @Test func readsCommentsOfIssueAcrossPages() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "repository": { "issue": { "comments": { "pageInfo": { "hasNextPage": true, "endCursor": "c1" }, "nodes": [
                  { "databaseId": 6122919485, "fullDatabaseId": "6122919485", "updatedAt": "2027-01-15T08:00:00Z", "body": "本文",
                    "author": { "login": "mrs1669" } },
                  null,
                  { "databaseId": null, "fullDatabaseId": "9007199254740993", "updatedAt": "2027-01-15T08:00:00Z", "body": "消されたユーザー",
                    "author": null },
                  { "databaseId": 13 }
                ] } } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "repository": { "issue": { "comments": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  { "databaseId": 14, "updatedAt": "2027-01-15T07:00:00Z", "body": "2 ページ目", "author": { "login": "partner" } }
                ] } } } } }
                """#)
        ])
        let source = GitHubLoopStatusSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))

        let comments = try await source.loopStatusComments(repository: "o/r", issue: 7)

        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        // id は 32 bit を超える（fullDatabaseId を先に読み、無ければ databaseId）
        #expect(comments == [
            LoopStatusComment(id: 6_122_919_485, author: "mrs1669", updatedAt: updatedAt, body: "本文"),
            LoopStatusComment(id: 9_007_199_254_740_993, author: nil, updatedAt: updatedAt, body: "消されたユーザー"),
            LoopStatusComment(id: 14, author: "partner", updatedAt: updatedAt.addingTimeInterval(-3600), body: "2 ページ目")
        ])
        let variables = try http.requests.map { request in
            let data = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(object["variables"] as? [String: Any])
        }
        #expect(variables.count == 2)
        #expect(variables[0]["after"] is NSNull)
        #expect(variables[0]["owner"] as? String == "o")
        #expect(variables[0]["name"] as? String == "r")
        #expect(variables[0]["number"] as? Int == 7)
        #expect(variables[1]["after"] as? String == "c1")
    }

    @Test func failsWhenIssueIsMissing() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "data": { "repository": { "issue": null } } }"#)])
        let source = GitHubLoopStatusSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
        await #expect(throws: GitHubError.self) {
            try await source.loopStatusComments(repository: "o/r", issue: 7)
        }
    }
}
