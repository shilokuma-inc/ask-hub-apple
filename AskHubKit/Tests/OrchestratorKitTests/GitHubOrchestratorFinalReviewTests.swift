import Foundation
@testable import OrchestratorKit
import Testing

// 最終 PR の第三者レビューの状態コメント（Discussion #503）
extension GitHubOrchestratorTests {
    @Test func createsAndUpdatesPullRequestComment() async throws {
        let http = StubHTTPClient(responses: [(201, #"{ "id": 31 }"#), (200, #"{ "id": 31 }"#)])
        let github = makeGitHub(http)
        #expect(try await github.createComment(onPullRequest: 70, in: "o/r", body: "進み具合") == 31)
        try await github.updateComment(in: "o/r", id: 31, body: "新しい進み具合")

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /repos/o/r/issues/70/comments",
            "PATCH /repos/o/r/issues/comments/31"
        ])
    }
}
