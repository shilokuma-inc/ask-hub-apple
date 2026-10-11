import Foundation

/// Issue のコメント
public struct IssueComment: Sendable, Equatable, Hashable, Identifiable {
    public let id: Int
    /// 削除済みのユーザーでは `nil`
    public let author: String?
    public let body: String
    /// 作成日時。取得元が読まない場合は `nil`
    public let createdAt: Date?
    /// GitHub 上のコメントの URL。取得元が読まない場合は `nil`
    public let url: URL?

    public init(id: Int, author: String?, body: String, createdAt: Date? = nil, url: URL? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}
