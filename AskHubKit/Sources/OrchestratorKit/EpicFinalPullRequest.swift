import Foundation

/// epic の最終 PR（`epic-final` が付いた open な PR）
public struct EpicFinalPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    /// epic ブランチ
    public let headBranch: String
    /// 作った人。削除済みのユーザーでは `nil`
    public let author: String?
    /// 本文の先頭のゴール元の Discussion の目印（`<!-- ask-hub:discussion N -->`）の番号。無ければ `nil`
    public let goalDiscussion: Int?

    public init(repository: String, number: Int, headBranch: String, author: String?, goalDiscussion: Int? = nil) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.author = author
        self.goalDiscussion = goalDiscussion
    }
}
