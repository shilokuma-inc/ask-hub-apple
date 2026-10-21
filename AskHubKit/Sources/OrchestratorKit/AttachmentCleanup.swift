import AskHubKit
import Foundation

/// 書いた人と本文（Discussion の本文・コメント・返信、epic の子 PR のレビューコメント）
public struct AuthoredText: Sendable, Equatable {
    /// 削除済みのユーザーでは `nil`
    public let author: String?
    public let body: String

    public init(author: String?, body: String) {
        self.author = author
        self.body = body
    }
}

/// `develop` などにマージ済みの最終 PR（`epic-final`）
public struct MergedEpicFinalPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    /// epic ブランチ
    public let headBranch: String
    /// 作った人。削除済みのユーザーでは `nil`
    public let author: String?
    /// 本文の先頭のゴール元の Discussion の目印（`<!-- ask-hub:discussion N -->`）の番号。無ければ `nil`
    public let goalDiscussion: Int?

    public init(repository: String, number: Int, headBranch: String, author: String?, goalDiscussion: Int?) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.author = author
        self.goalDiscussion = goalDiscussion
    }
}

/// 添付を消せないときのエラー
public enum AttachmentCleanupError: Error, Equatable, Sendable {
    /// ブランチが先に進んでいて、ref を更新できなかった（次のポーリングでやり直す）
    case conflict
}

/// 最終 PR のマージ後の添付の片付け（Discussion #669 の Q7。`docs/protocol.md` の「添付ファイル」の「片付け」）。副作用なし
public enum AttachmentCleanup {
    /// 済んだ印のコメントの先頭に置く目印
    public static let markerKeyword = "ask-hub:attachments-cleaned"

    /// 信用する author が書いた本文の目印が指すパス（`files/` の下だけ。重ならないように、現れた順）。
    /// 信用しない author の目印は使わない（誰でもコメントできるので、ほかの epic の添付を消させないため）
    public static func paths(in texts: [AuthoredText], trustedAuthors: TrustedAuthors) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for text in texts where trustedAuthors.contains(text.author) {
            for marker in AttachmentMarker.parseAll(text.body) where seen.insert(marker.path).inserted {
                paths.append(marker.path)
            }
        }
        return paths
    }

    /// 済んだ印として最終 PR に付けるコメント
    public static func comment(deleted: Int, found: Int) -> String {
        """
        <!-- \(markerKeyword) {"count":\(deleted)} -->
        この epic の添付ファイル \(found) 件のうち、\(deleted) 件を `\(AttachmentMarker.branch)` ブランチから消しました（残りは既に消えていました）。
        git の履歴には残ります。（askhub-orchestrator）
        """
    }

    /// 信用する author の、済んだ印のコメントがあるか（あれば二度と処理しない）
    public static func isCleaned(_ comments: [IssueComment], trustedAuthors: TrustedAuthors) -> Bool {
        comments.contains { comment in
            trustedAuthors.contains(comment.author)
                && comment.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!-- \(markerKeyword) ")
        }
    }
}
