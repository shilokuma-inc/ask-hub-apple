import Foundation

/// 実機確認の Issue を、確認済み（完了）として閉じる。テストでは差し替える
public protocol IssueClosing: Sendable {
    /// 実機確認（`needs-verify`）の Issue を、完了（`state_reason: completed`）として閉じる。閉じた Issue は GitHub で開き直せる
    func closeAsVerified(_ issue: InboxIssue) async throws
}

/// Issue を閉じられないときのエラー
public enum IssueClosingError: Error, Equatable, Sendable {
    /// 実機確認以外の Issue は閉じない（仮決め一覧はオーケストレーターが最終 PR のマージ時に閉じる）
    case notNeedsVerify
}

/// GitHub の REST API で Issue を閉じる（Discussion #331 の Q5）。トークンには Issues の書き込み権限が要る
public struct GitHubIssueCloser: IssueClosing {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func closeAsVerified(_ issue: InboxIssue) async throws {
        guard issue.kind == .needsVerify else {
            throw IssueClosingError.notNeedsVerify
        }
        _ = try await client.send(
            "PATCH",
            "repos/\(issue.repository)/issues/\(issue.number)",
            body: CloseRequest(state: "closed", stateReason: "completed"),
            as: ClosedIssue.self
        )
    }
}

private struct CloseRequest: Encodable, Sendable {
    let state: String
    let stateReason: String

    private enum CodingKeys: String, CodingKey {
        case state
        case stateReason = "state_reason"
    }
}

private struct ClosedIssue: Decodable {
    let number: Int
}
