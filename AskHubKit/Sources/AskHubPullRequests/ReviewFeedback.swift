import Foundation

/// 指示として読んでよい書き手（CodeRabbit など）。public のリポジトリでは誰でもコメントできるので、読む前に必ず絞る。
///
/// login は REST の形で渡す（bot は `coderabbitai[bot]`）。大文字小文字は区別しない。
/// GraphQL は bot の login を `coderabbitai` で返すので、`__typename` が `Bot` のときだけ `[bot]` を足して比べる
/// （同じ名前の人のアカウントを bot と取り違えない）
public struct TrustedAuthors: Sendable, Equatable {
    public let logins: Set<String>

    public init(_ logins: some Sequence<String>) {
        self.logins = Set(logins.map { $0.lowercased() })
    }

    /// REST の `user`（`login` と `type`）
    func contains(restLogin login: String, type: String?) -> Bool {
        guard type == nil || type == "User" || type == "Bot" else { return false }
        return logins.contains(login.lowercased())
    }

    /// GraphQL の `author`（`__typename` と `login`）。人と bot のほか（Mannequin など）は信用しない
    func contains(graphQLLogin login: String, typename: String) -> Bool {
        switch typename {
        case "User": logins.contains(login.lowercased())
        case "Bot": logins.contains("\(login)[bot]".lowercased())
        default: false
        }
    }
}

/// 信用する書き手の、まだ対応していないレビューの指摘
public struct ReviewFeedback: Sendable, Equatable {
    /// 未解決で、最初のコメントが信用する書き手のスレッド（行コメント）
    public var threads: [ReviewThread]
    /// 信用する書き手のレビューの本文（CodeRabbit の Nitpick などは行コメントでなく本文の折りたたみに入る）
    public var reviews: [ReviewBody]

    public init(threads: [ReviewThread], reviews: [ReviewBody]) {
        self.threads = threads
        self.reviews = reviews
    }
}

/// 行コメントのスレッド
public struct ReviewThread: Sendable, Equatable {
    /// GraphQL の node id（解決済みにするときに使う）
    public var id: String
    public var path: String?
    /// 今の差分での行。差分が変わって当てはまらなくなったら nil
    public var line: Int?
    /// コメントの後に、その行が変わった
    public var isOutdated: Bool
    /// 信用する書き手のコメントだけ（古い順。最初がスレッドの起点）
    public var comments: [ReviewComment]

    public init(id: String, path: String?, line: Int?, isOutdated: Bool, comments: [ReviewComment]) {
        self.id = id
        self.path = path
        self.line = line
        self.isOutdated = isOutdated
        self.comments = comments
    }
}

/// 行コメント
public struct ReviewComment: Sendable, Equatable {
    /// REST のコメントの id（`pulls/<n>/comments/<id>/replies` で返信できる）
    public var id: Int?
    /// REST の形の login（bot は `[bot]` 付き）
    public var author: String
    public var body: String
    public var url: URL?
    public var createdAt: Date?

    public init(id: Int?, author: String, body: String, url: URL? = nil, createdAt: Date? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.createdAt = createdAt
    }
}

/// レビューの本文
public struct ReviewBody: Sendable, Equatable {
    public var id: Int
    /// REST の形の login（bot は `[bot]` 付き）
    public var author: String
    /// `COMMENTED`・`CHANGES_REQUESTED`・`APPROVED`
    public var state: String
    public var body: String
    /// レビューしたコミット
    public var commitID: String?
    public var submittedAt: Date?
    public var url: URL?

    public init(
        id: Int,
        author: String,
        state: String,
        body: String,
        commitID: String? = nil,
        submittedAt: Date? = nil,
        url: URL? = nil
    ) {
        self.id = id
        self.author = author
        self.state = state
        self.body = body
        self.commitID = commitID
        self.submittedAt = submittedAt
        self.url = url
    }
}
