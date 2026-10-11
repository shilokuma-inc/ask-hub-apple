import Foundation

/// 仮決め一覧のコメントを取得する。テストでは差し替える
public protocol DecisionLogCommentsFetching: Sendable {
    /// 仮決め一覧（`decision-log`）のコメントを、ページングを最後まで追って古い順（作成順）に返す
    func comments(of issue: InboxIssue) async throws -> [IssueComment]
}

/// コメントを取得できないときのエラー
public enum DecisionLogCommentsError: Error, Equatable, Sendable {
    /// 仮決め一覧以外の Issue のコメントは読まない
    case notDecisionLog
}

/// GitHub の REST API で仮決め一覧のコメントを取得する
public struct GitHubDecisionLogComments: DecisionLogCommentsFetching {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func comments(of issue: InboxIssue) async throws -> [IssueComment] {
        guard issue.kind == .decisionLog else {
            throw DecisionLogCommentsError.notDecisionLog
        }
        let comments = try await client.getAllPages(
            "repos/\(issue.repository)/issues/\(issue.number)/comments",
            of: CommentSummary.self
        )
        // 処理済みの判定は並び順に依存するので、API の並びに頼らず作成順（同時刻は id 順）に並べ直す
        return comments
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            .map { IssueComment(id: $0.id, author: $0.user?.login, body: $0.body ?? "", createdAt: $0.createdAt, url: $0.htmlURL) }
    }
}

private struct CommentSummary: Decodable {
    let id: Int
    let user: User?
    let body: String?
    let createdAt: Date
    let htmlURL: URL

    struct User: Decodable {
        let login: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
        case htmlURL = "html_url"
    }
}
