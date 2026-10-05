import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - ready-for-loop の Discussion へのコメント

extension GitHubOrchestratorTests {
    @Test func commentsOnReadyDiscussionWithGraphQL() async throws {
        let http = StubHTTPClient([#"{ "data": { "addDiscussionComment": { "comment": { "id": "DC_1" } } } }"#])
        try await makeGitHub(http).comment(on: .fixture(number: 12), body: "やることがありません")

        let mutation = try requestJSON(http.requests[0])
        #expect(mutation.query.contains("addDiscussionComment"))
        #expect(mutation.variables["discussion"] as? String == ReadyDiscussion.fixture(number: 12).nodeID)
        #expect(mutation.variables["body"] as? String == "やることがありません")
    }

    @Test func failsToCommentWhenPayloadIsNull() async throws {
        // 権限不足などでは payload が null になる。失敗として返し、呼び出し側が次のポーリングで再試行する
        let http = StubHTTPClient([#"{ "data": { "addDiscussionComment": null } }"#])
        await #expect(throws: (any Error).self) {
            try await self.makeGitHub(http).comment(on: .fixture(number: 12), body: "x")
        }
    }
}
