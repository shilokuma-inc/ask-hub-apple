import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 担当リポジトリの作成・追加・削除の依頼（repo-request）に使う GitHub の操作
extension GitHubOrchestratorTests {
    @Test func readsHeartbeatLastSeenOfRepository() async throws {
        let description = OrchestratorHeartbeat.description(at: Date(timeIntervalSince1970: 1_800_000_000))
        let label = try JSONSerialization.data(withJSONObject: ["name": "askhub-orchestrator", "description": description])
        let http = StubHTTPClient([try #require(String(bytes: label, encoding: .utf8))])

        let lastSeen = try await makeGitHub(http).heartbeatLastSeen(in: "o/r")

        #expect(lastSeen == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["GET /repos/o/r/labels/askhub-orchestrator"])
    }

    @Test func treatsMissingOrUnreadableHeartbeatAsNone() async throws {
        let missing = StubHTTPClient(responses: [(404, #"{ "message": "Not Found" }"#)])
        #expect(try await makeGitHub(missing).heartbeatLastSeen(in: "o/r") == nil)

        // ラベルはあるが、説明が担当の印の形でない（人が作ったラベルなど）
        let other = StubHTTPClient([#"{ "name": "askhub-orchestrator", "description": null }"#])
        #expect(try await makeGitHub(other).heartbeatLastSeen(in: "o/r") == nil)
    }

    @Test func throwsWhenHeartbeatCannotBeRead() async {
        let http = StubHTTPClient(responses: [(500, #"{ "message": "Server Error" }"#)])
        await #expect(throws: GitHubError.self) {
            try await makeGitHub(http).heartbeatLastSeen(in: "o/r")
        }
    }
}
