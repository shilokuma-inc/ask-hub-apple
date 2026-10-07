@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusRowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])

    private func issue(
        _ number: Int, author: String? = "mrs1669", updatedMinutesAgo: Double = 0, report: LoopStatusReport?
    ) -> LoopStatusIssue {
        LoopStatusIssue(
            number: number,
            url: URL(string: "https://github.com/o/r/issues/\(number)")!,
            author: author,
            updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60),
            body: report?.issueBody ?? "人が書いた本文"
        )
    }

    private func report(_ state: LoopStatusReport.State, checkedMinutesAgo: Double = 0) -> LoopStatusReport {
        LoopStatusReport(state: state, epic: "epic/x", discussion: 12, checkedAt: now.addingTimeInterval(-checkedMinutesAgo * 60))
    }

    @Test func usesNewestTrustedIssueAndIgnoresOthers() {
        let repositories = [
            LoopStatusRepository(repository: "o/r", heartbeatDescription: OrchestratorHeartbeat.description(at: now), issues: [
                // 信用しない author のほうが新しくても使わない
                issue(9, author: "someone", updatedMinutesAgo: 0, report: report(.gaveUp)),
                issue(1, updatedMinutesAgo: 30, report: report(.completed)),
                issue(2, updatedMinutesAgo: 5, report: report(.running)),
                // 目印の無い本文は読めないので使わない
                issue(3, updatedMinutesAgo: 1, report: nil),
                issue(4, author: nil, updatedMinutesAgo: 1, report: report(.noLoop))
            ])
        ]
        let rows = LoopStatusRow.rows(from: repositories, trustedAuthors: trusted)
        #expect(rows.count == 1)
        #expect(rows[0].report == report(.running))
        #expect(rows[0].issueURL == URL(string: "https://github.com/o/r/issues/2"))
        #expect(rows[0].lastSeen == now)
        #expect(rows[0].status(now: now) == .reported(report(.running)))
        #expect(rows[0].discussionURL == URL(string: "https://github.com/o/r/discussions/12"))
    }

    @Test func includesRepositoriesWithHeartbeatOrTrustedIssueSortedByName() {
        let stale = OrchestratorHeartbeat.description(at: now.addingTimeInterval(-60 * 60))
        let repositories = [
            // 担当の印も信用する author の Issue も無いリポジトリは出さない
            LoopStatusRepository(repository: "o/none", heartbeatDescription: nil, issues: [
                issue(1, author: "someone", report: report(.running))
            ]),
            LoopStatusRepository(repository: "o/human-label", heartbeatDescription: "人が付けた説明", issues: []),
            LoopStatusRepository(repository: "o/Zeta", heartbeatDescription: OrchestratorHeartbeat.description(at: now), issues: []),
            LoopStatusRepository(repository: "o/beta", heartbeatDescription: stale, issues: []),
            LoopStatusRepository(repository: "o/alpha", heartbeatDescription: nil, issues: [issue(1, report: report(.running))])
        ]
        let rows = LoopStatusRow.rows(from: repositories, trustedAuthors: trusted)
        #expect(rows.map(\.repository) == ["o/alpha", "o/beta", "o/Zeta"])
        // 状態の Issue がまだ無い（担当 PC はいる）
        #expect(rows[2].status(now: now) == .notReported)
        #expect(rows[2].discussionURL == nil)
        // 担当の印が古い
        #expect(rows[1].status(now: now) == .unassigned)
        // 担当の印が無くても、状態の確認時刻が新しければ担当 PC はいる
        #expect(rows[0].status(now: now) == .reported(report(.running)))
    }

    @Test func keepsRepositoryWhoseTrustedIssueCannotBeParsed() {
        let repositories = [
            LoopStatusRepository(repository: "o/r", heartbeatDescription: nil, issues: [issue(3, report: nil)]),
            LoopStatusRepository(repository: "o/s", heartbeatDescription: nil, issues: [issue(4, author: "someone", report: nil)])
        ]
        let rows = LoopStatusRow.rows(from: repositories, trustedAuthors: trusted)
        #expect(rows.map(\.repository) == ["o/r"])
        #expect(rows[0].report == nil)
        #expect(rows[0].issueURL == URL(string: "https://github.com/o/r/issues/3"))
        #expect(rows[0].status(now: now) == .unassigned)
        let heartbeat = OrchestratorHeartbeat.description(at: now)
        let assigned = LoopStatusRow.rows(from: [
            LoopStatusRepository(repository: "o/r", heartbeatDescription: heartbeat, issues: [issue(3, report: nil)])
        ], trustedAuthors: trusted)
        #expect(assigned.first?.status(now: now) == .notReported)
    }

    @Test func treatsRowAsUnassignedOnlyWhenBothTimesAreStale() {
        let fresh = report(.running, checkedMinutesAgo: 10)
        let staleReport = report(.running, checkedMinutesAgo: 40)
        let staleHeartbeat = now.addingTimeInterval(-40 * 60)
        #expect(LoopStatusRow(repository: "o/r", report: fresh, lastSeen: staleHeartbeat).status(now: now) == .reported(fresh))
        #expect(LoopStatusRow(repository: "o/r", report: staleReport, lastSeen: now).status(now: now) == .reported(staleReport))
        #expect(LoopStatusRow(repository: "o/r", report: staleReport, lastSeen: staleHeartbeat).status(now: now) == .unassigned)
        #expect(LoopStatusRow(repository: "o/r", report: nil, lastSeen: nil).status(now: now) == .unassigned)
    }

    @Test func fetcherFiltersThroughTrustedAuthors() async throws {
        struct Source: LoopStatusSource {
            let repositories: [LoopStatusRepository]
            func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
                repositories
            }
        }
        let source = Source(repositories: [
            LoopStatusRepository(
                repository: "o/r", heartbeatDescription: nil, issues: [issue(1, author: "someone", report: report(.running))]
            )
        ])
        #expect(try await LoopStatusFetcher(source: source, trustedAuthors: trusted).rows(orgs: ["o"]).isEmpty)
        let trustingSomeone = LoopStatusFetcher(source: source, trustedAuthors: TrustedAuthors(["someone"]))
        #expect(try await trustingSomeone.rows(orgs: ["o"]).map(\.repository) == ["o/r"])
    }

    @Test func statusIssuesAreNotLowPriorityIssues() {
        // 「急がない」はラベルで検索するので、状態用のラベルを含めない
        #expect(!InboxIssue.Kind.labels.contains(.loopStatus))
        #expect(InboxIssue.Kind(labelNames: [LoopStatusReport.labelName]) == nil)
    }
}

struct GitHubLoopStatusSourceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func issueJSON(_ number: Int, repository: String, author: String?, body: String) -> String {
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let authorJSON = author.map { #"{ "login": "\#($0)" }"# } ?? "null"
        return #"""
            { "number": \#(number), "url": "https://github.com/\#(repository)/issues/\#(number)", "updatedAt": "2027-01-15T08:00:00Z",
              "body": "\#(escaped)", "author": \#(authorJSON) }
            """#
    }

    /// リポジトリの一覧が 2 ページ、o/a の Issue が 1 ページ目に収まらず続きが 2 ページ
    private func pagedResponses(heartbeat: String, body: String) -> MockHTTPClient {
        MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "organization": { "repositories": { "pageInfo": { "hasNextPage": true, "endCursor": "r1" }, "nodes": [
                  { "nameWithOwner": "o/a", "label": { "description": "\#(heartbeat)" },
                    "issues": { "pageInfo": { "hasNextPage": true, "endCursor": "i1" }, "nodes": [
                      \#(issueJSON(5, repository: "o/a", author: "someone", body: "spam"))
                    ] } },
                  null
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "organization": { "repositories": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  { "nameWithOwner": "o/b", "label": null,
                    "issues": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } }
                ] } } } }
                """#),
            // o/a の Issue の続き（2 ページ）
            .init(status: 200, body: #"""
                { "data": { "repository": { "issues": { "pageInfo": { "hasNextPage": true, "endCursor": "i2" }, "nodes": [
                  \#(issueJSON(6, repository: "o/a", author: "someone", body: "spam"))
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "repository": { "issues": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  \#(issueJSON(1, repository: "o/a", author: "mrs1669", body: body)), null, {}
                ] } } } }
                """#)
        ])
    }

    @Test func readsRepositoriesAndRemainingIssuesAcrossPages() async throws {
        let heartbeat = OrchestratorHeartbeat.description(at: now)
        let body = LoopStatusReport(state: .running, epic: "epic/x", checkedAt: now).issueBody
        let http = pagedResponses(heartbeat: heartbeat, body: body)
        let source = GitHubLoopStatusSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))

        let repositories = try await source.loopStatusRepositories(orgs: ["shilokuma-inc"])

        #expect(repositories.map(\.repository) == ["o/a", "o/b"])
        #expect(repositories[0].heartbeatDescription == heartbeat)
        #expect(repositories[0].issues.map(\.number) == [5, 6, 1])
        #expect(repositories[0].issues.map(\.author) == ["someone", "someone", "mrs1669"])
        #expect(repositories[1].heartbeatDescription == nil)
        #expect(repositories[1].issues.isEmpty)

        let rows = LoopStatusRow.rows(from: repositories, trustedAuthors: .default)
        #expect(rows.map(\.repository) == ["o/a"])
        #expect(rows.first?.report?.state == .running)

        let variables = try http.requests.map { request in
            let data = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(object["variables"] as? [String: Any])
        }
        #expect(variables.count == 4)
        #expect(variables[0]["org"] as? String == "shilokuma-inc")
        #expect(variables[0]["label"] as? String == "askhub-orchestrator")
        #expect(variables[0]["statusLabel"] as? String == "loop-status")
        // リポジトリの一覧を最後まで取ってから、Issue の続きを 1 ページ目のカーソルから取る
        #expect(variables[1]["after"] as? String == "r1")
        #expect(variables[2]["owner"] as? String == "o")
        #expect(variables[2]["name"] as? String == "a")
        #expect(variables[2]["after"] as? String == "i1")
        #expect(variables[3]["after"] as? String == "i2")
    }

    @Test func readsEachOrganizationInOrder() async throws {
        let http = MockHTTPClient(["a/x", "b/y"].map { name in
            .init(status: 200, body: #"""
                { "data": { "organization": { "repositories": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  { "nameWithOwner": "\#(name)", "label": null,
                    "issues": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [] } }
                ] } } } }
                """#)
        })
        let source = GitHubLoopStatusSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))

        let repositories = try await source.loopStatusRepositories(orgs: ["a", "b"])

        #expect(repositories.map(\.repository) == ["a/x", "b/y"])
        let orgs = try http.requests.map { request in
            let data = try #require(request.httpBody)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (object["variables"] as? [String: Any])?["org"] as? String
        }
        #expect(orgs == ["a", "b"])
    }

    @Test func failsWhenOrganizationIsMissing() async {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "data": { "organization": null } }"#)])
        let source = GitHubLoopStatusSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
        await #expect(throws: GitHubError.self) {
            try await source.loopStatusRepositories(orgs: ["o"])
        }
    }
}
