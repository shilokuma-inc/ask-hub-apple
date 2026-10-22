import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 状態用の Issue（loop-status）を番号で読む（一覧に見当たらないときの確かめ。Issue #739）
extension GitHubOrchestratorTests {
    @Test func readsLoopStatusIssueByNumberOnlyWhileItIsLabeledIssue() async throws {
        let http = StubHTTPClient(responses: [
            (200, #"""
            { "number": 3, "state": "closed", "body": "本文", "user": { "login": "mrs1669" }, "updated_at": "2027-01-15T08:00:00Z",
              "labels": [{ "name": "bug" }, { "name": "loop-status" }] }
            """#),
            // ラベルが外された
            (200, #"""
            { "number": 3, "state": "open", "body": "", "user": { "login": "mrs1669" }, "updated_at": "2027-01-15T08:00:00Z",
              "labels": [] }
            """#),
            // PR（Issue の API は PR も返す）
            (200, #"""
            { "number": 3, "state": "open", "body": "", "user": { "login": "mrs1669" }, "updated_at": "2027-01-15T08:00:00Z",
              "labels": [{ "name": "loop-status" }], "pull_request": { "url": "https://api.github.com/repos/o/r/pulls/3" } }
            """#),
            // 消された・無い
            (410, #"{ "message": "This issue was deleted" }"#),
            (404, #"{ "message": "Not Found" }"#)
        ])
        let github = makeGitHub(http)

        #expect(try await github.loopStatusIssue(in: "o/r", number: 3) == LoopStatusIssueRecord(
            number: 3, author: "mrs1669", isOpen: false, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), body: "本文"
        ))
        for _ in 0..<4 {
            #expect(try await github.loopStatusIssue(in: "o/r", number: 3) == nil)
        }
        let requests = http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(requests == Array(repeating: "GET /repos/o/r/issues/3", count: 5))
    }
}
