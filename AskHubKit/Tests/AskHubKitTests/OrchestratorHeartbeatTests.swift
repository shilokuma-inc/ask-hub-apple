@testable import AskHubKit
import Foundation
import Testing

struct OrchestratorHeartbeatTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func roundTripsDescriptionWithinLabelLimit() {
        let description = OrchestratorHeartbeat.description(at: now)
        #expect(description.count <= 100)
        #expect(OrchestratorHeartbeat.lastSeen(in: description) == now)
        #expect(OrchestratorHeartbeat.lastSeen(in: "人が付けた説明") == nil)
        #expect(OrchestratorHeartbeat.lastSeen(in: nil) == nil)
    }

    @Test func roundTripsUsageLimitWithinLabelLimit() {
        let until = now.addingTimeInterval(2 * 60 * 60)
        let description = OrchestratorHeartbeat.description(at: now, usageLimitedUntil: until)
        #expect(description.count <= 100)
        #expect(OrchestratorHeartbeat.lastSeen(in: description) == now)
        #expect(OrchestratorHeartbeat.usageLimitedUntil(in: description) == until)
        // 上限の時刻が無い印（これまでの形式）も読める
        #expect(OrchestratorHeartbeat.usageLimitedUntil(in: OrchestratorHeartbeat.description(at: now)) == nil)
        #expect(OrchestratorHeartbeat.lastSeen(in: OrchestratorHeartbeat.description(at: now)) == now)

        #expect(OrchestratorHeartbeat.isUsageLimited(until: until, now: now))
        #expect(!OrchestratorHeartbeat.isUsageLimited(until: now, now: now))
        #expect(!OrchestratorHeartbeat.isUsageLimited(until: nil, now: now))
    }

    @Test func waitingDiscussionIsUsageLimitedOnlyWhileAssigned() {
        let subject = InboxSubject(
            kind: .discussion, nodeID: "D_1", repository: "o/r", number: 1, title: "T", url: URL(string: "https://github.com/o/r/discussions/1")!
        )
        let until = now.addingTimeInterval(60 * 60)
        #expect(WaitingDiscussion(subject: subject, lastSeen: now, usageLimitedUntil: until).isUsageLimited(now: now))
        // 担当の印が古ければ「担当 PC なし」を優先する
        let stale = WaitingDiscussion(subject: subject, lastSeen: now.addingTimeInterval(-60 * 60), usageLimitedUntil: until)
        #expect(!stale.isUsageLimited(now: now))
    }

    @Test func assignedOnlyWhileHeartbeatIsFresh() {
        #expect(OrchestratorHeartbeat.isAssigned(lastSeen: now.addingTimeInterval(-29 * 60), now: now))
        #expect(!OrchestratorHeartbeat.isAssigned(lastSeen: now.addingTimeInterval(-31 * 60), now: now))
        #expect(!OrchestratorHeartbeat.isAssigned(lastSeen: nil, now: now))
    }
}

struct WaitingDiscussionSourceTests {
    @Test func readsReadyDiscussionsWithRepositoryHeartbeat() async throws {
        let seen = OrchestratorHeartbeat.description(at: Date(timeIntervalSince1970: 1_800_000_000))
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  { "id": "D_3", "number": 3, "title": "通知", "url": "https://github.com/o/r/discussions/3", "closed": false,
                    "author": { "login": "mrs1669" },
                    "repository": { "nameWithOwner": "o/r", "label": { "description": "\#(seen)" } } },
                  { "id": "D_4", "number": 4, "title": "担当なし", "url": "https://github.com/o/r2/discussions/4", "closed": false,
                    "repository": { "nameWithOwner": "o/r2", "label": null } },
                  { "id": "D_5", "number": 5, "title": "閉じた", "url": "https://github.com/o/r/discussions/5", "closed": true,
                    "repository": { "nameWithOwner": "o/r", "label": null } },
                  {}
                ] } } }
                """#)
        ])
        let source = GitHubInboxSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
        let waiting = try await source.waitingDiscussions(org: "shilokuma-inc")

        #expect(waiting.map(\.subject.nodeID) == ["D_3", "D_4"])
        #expect(waiting.map(\.lastSeen) == [Date(timeIntervalSince1970: 1_800_000_000), nil])
        #expect(waiting.map(\.author) == ["mrs1669", nil])
        let data = try #require(http.requests.first?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(object["variables"] as? [String: Any])
        #expect(variables["query"] as? String == "org:shilokuma-inc label:ready-for-loop is:open")
        #expect(variables["label"] as? String == "askhub-orchestrator")
    }
}

struct UsageLimitedRepositorySourceTests {
    @Test func readsUsageLimitedRepositoriesAcrossPages() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let limited = OrchestratorHeartbeat.description(at: now, usageLimitedUntil: now.addingTimeInterval(3600))
        let sooner = OrchestratorHeartbeat.description(at: now, usageLimitedUntil: now.addingTimeInterval(600))
        let expired = OrchestratorHeartbeat.description(at: now, usageLimitedUntil: now.addingTimeInterval(-60))
        let stale = OrchestratorHeartbeat.description(at: now.addingTimeInterval(-3600), usageLimitedUntil: now.addingTimeInterval(3600))
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "organization": { "repositories": { "pageInfo": { "hasNextPage": true, "endCursor": "c1" }, "nodes": [
                  { "nameWithOwner": "o/a", "label": { "description": "\#(limited)" } },
                  { "nameWithOwner": "o/b", "label": { "description": "\#(expired)" } },
                  null
                ] } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "organization": { "repositories": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  { "nameWithOwner": "o/c", "label": { "description": "\#(sooner)" } },
                  { "nameWithOwner": "o/d", "label": { "description": "\#(stale)" } },
                  { "nameWithOwner": "o/e", "label": null }
                ] } } } }
                """#)
        ])
        let source = GitHubInboxSource(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))

        let repositories = try await source.usageLimitedRepositories(org: "o", now: now)

        // 解除済み・担当の印が古い・印なしは除き、解除の早い順に並べる
        #expect(repositories == [
            UsageLimitedRepository(repository: "o/c", until: now.addingTimeInterval(600)),
            UsageLimitedRepository(repository: "o/a", until: now.addingTimeInterval(3600))
        ])
    }
}
