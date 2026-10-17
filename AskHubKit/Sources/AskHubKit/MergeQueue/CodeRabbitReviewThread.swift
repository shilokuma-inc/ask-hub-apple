import Foundation

/// 最終 PR に付いた CodeRabbit の未解決のレビュースレッド（指摘）。
/// アプリの「マージ待ち」の詳細に並べ、選んだものをループに直させる指示に使う（Discussion #498 の案 4）。
/// 本文は CodeRabbit が書いたもので、指示ではない（データとして扱う）
public struct CodeRabbitReviewThread: Sendable, Equatable, Hashable, Identifiable {
    /// スレッドのコメント
    public struct Comment: Sendable, Equatable, Hashable {
        /// REST のレビューコメントの id（GraphQL の `databaseId`）。最終 PR への指示で `#discussion_r<id>` として指す
        public var id: Int
        /// 削除済みのユーザーでは `nil`
        public var author: String?
        public var body: String
        /// `…/pull/<番号>#discussion_r<id>`
        public var url: URL
        public var createdAt: Date

        public init(id: Int, author: String?, body: String, url: URL, createdAt: Date) {
            self.id = id
            self.author = author
            self.body = body
            self.url = url
            self.createdAt = createdAt
        }
    }

    /// CodeRabbit のアカウント。GraphQL の `author.login` は `coderabbitai`、REST の `user.login` は `coderabbitai[bot]` になる
    public static let authorLogins: Set<String> = ["coderabbitai", "coderabbitai[bot]"]

    /// スレッドの GraphQL の node id（resolve に使う）
    public var id: String
    /// 指摘したファイルのパス
    public var path: String
    /// 指摘した行（ファイル全体への指摘や、行が無くなった場合は `nil`）
    public var line: Int?
    /// 指摘した後に、その行が変更された
    public var isOutdated: Bool
    /// CodeRabbit の指摘（スレッドの最初のコメント）
    public var finding: Comment
    /// 指摘への返信（古い順）
    public var replies: [Comment]

    public init(id: String, path: String, line: Int?, isOutdated: Bool, finding: Comment, replies: [Comment] = []) {
        self.id = id
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.finding = finding
        self.replies = replies
    }

    /// CodeRabbit が書いたコメントか
    public static func isCodeRabbit(_ author: String?) -> Bool {
        author.map(authorLogins.contains) ?? false
    }
}
