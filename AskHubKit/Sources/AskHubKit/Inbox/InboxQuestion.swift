import Foundation

/// 質問が置かれている場所（Discussion または PR）
public struct InboxSubject: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        /// ※1 Discussion の質問
        case discussion
        /// ※2 PR の ask
        case pullRequest
    }

    public var kind: Kind
    /// GraphQL の node id。コメントの取得や返信に使う
    public var nodeID: String
    /// `owner/repo`
    public var repository: String
    public var number: Int
    public var title: String
    public var url: URL

    public init(kind: Kind, nodeID: String, repository: String, number: Int, title: String, url: URL) {
        self.kind = kind
        self.nodeID = nodeID
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
    }
}

/// 質問かもしれないコメント
public struct InboxComment: Sendable, Equatable, Hashable {
    /// GraphQL の node id。Discussion のコメントへの返信に使う
    public var nodeID: String
    /// REST の id。PR のレビューコメントへの返信（`in_reply_to`）に使う
    public var databaseID: Int?
    /// 削除済みのユーザーでは `nil`
    public var author: String?
    public var body: String
    public var url: URL
    public var createdAt: Date

    public init(nodeID: String, databaseID: Int?, author: String?, body: String, url: URL, createdAt: Date) {
        self.nodeID = nodeID
        self.databaseID = databaseID
        self.author = author
        self.body = body
        self.url = url
        self.createdAt = createdAt
    }
}

/// スレッドの先頭のコメントと、それへの返信の author。
///
/// Discussion ではコメントとその返信、PR ではレビュースレッドの最初のコメントと 2 件目以降にあたる
public struct QuestionThread: Sendable, Equatable {
    public var comment: InboxComment
    public var replyAuthors: [String?]

    public init(comment: InboxComment, replyAuthors: [String?]) {
        self.comment = comment
        self.replyAuthors = replyAuthors
    }
}

/// 受信箱の「要回答」に出す、未回答の質問
public struct InboxQuestion: Sendable, Equatable, Identifiable {
    public var subject: InboxSubject
    public var comment: InboxComment
    public var marker: QuestionMarker

    public init(subject: InboxSubject, comment: InboxComment, marker: QuestionMarker) {
        self.subject = subject
        self.comment = comment
        self.marker = marker
    }

    /// 質問のコメントの node id。リポジトリをまたいでも一意
    public var id: String {
        comment.nodeID
    }

    /// 先頭の目印を除いた質問の本文（表示用）
    public var questionBody: String {
        let body = comment.body.drop { $0.isWhitespace || $0.isNewline }
        guard let close = body.range(of: QuestionMarker.commentClose) else {
            return String(body)
        }
        return body[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// スレッドのうち、未回答の質問だけを返す。
    ///
    /// 信用する author が書いた目印だけを質問とみなし、信用する author の返信が 1 件以上あれば回答済みとして除く
    /// （`docs/protocol.md` の「質問の目印」「回答済みの判定」）
    public static func unanswered(
        in threads: [QuestionThread],
        of subject: InboxSubject,
        trustedAuthors: TrustedAuthors
    ) -> [Self] {
        threads.compactMap { thread in
            guard let marker = trustedAuthors.question(in: thread.comment.body, author: thread.comment.author),
                  !trustedAuthors.isAnswered(replyAuthors: thread.replyAuthors) else {
                return nil
            }
            return Self(subject: subject, comment: thread.comment, marker: marker)
        }
    }
}
