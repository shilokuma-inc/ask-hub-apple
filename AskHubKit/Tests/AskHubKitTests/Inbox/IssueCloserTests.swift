@testable import AskHubKit
import Foundation
import Testing

struct GitHubIssueCloserTests {
    private func makeCloser(_ http: MockHTTPClient) -> GitHubIssueCloser {
        GitHubIssueCloser(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private static func issue(_ kind: InboxIssue.Kind) -> InboxIssue {
        InboxIssue(
            id: "I_18",
            kind: kind,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 18,
            title: "【CHORE】実機確認: 通知の表示",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func closesVerificationIssueAsCompleted() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "number": 18, "state": "closed" }"#)])
        try await makeCloser(http).closeAsVerified(Self.issue(.needsVerify))

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "PATCH /repos/shilokuma-inc/ask-hub-apple/issues/18"
        ])
        let data = try #require(http.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["state": "closed", "state_reason": "completed"])
    }

    @Test func refusesToCloseDecisionLog() async {
        // 仮決め一覧はオーケストレーターが最終 PR のマージ時に閉じる
        let http = MockHTTPClient([])
        await #expect(throws: IssueClosingError.notNeedsVerify) {
            try await makeCloser(http).closeAsVerified(Self.issue(.decisionLog))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func reportsMissingPermission() async {
        // トークンに Issues の書き込み権限が無いと、GitHub は 403（リポジトリが見えなければ 404）で断る
        let message = "Resource not accessible by personal access token"
        let http = MockHTTPClient([.init(status: 403, body: #"{ "message": "\#(message)" }"#)])
        await #expect(throws: GitHubError.http(status: 403, message: message)) {
            try await makeCloser(http).closeAsVerified(Self.issue(.needsVerify))
        }
    }
}
