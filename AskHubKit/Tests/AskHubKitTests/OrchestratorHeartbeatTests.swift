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
