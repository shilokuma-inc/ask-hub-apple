import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// Discussion の写しを読み書きする GitHub の API（`DiscussionMirror` が使う）。テストでは差し替える
public protocol DiscussionAPI: Sendable {
    /// リポジトリの id と、Discussions の設定（有効か・カテゴリ）
    func repository(_ repo: RepositoryFullName) async throws(DiscussionError) -> DiscussionRepository
    /// 番号の Discussion と、そのコメント（返信を含む）。無ければ nil
    func discussion(_ repo: RepositoryFullName, number: Int) async throws(DiscussionError) -> DiscussionThread?
    /// `since` より後に作られた Discussion（新しい順）
    func discussions(_ repo: RepositoryFullName, createdSince since: Date) async throws(DiscussionError) -> [DiscussionSummary]
    /// `ids` のうち、無い（消された）もの
    func missing(_ ids: [String]) async throws(DiscussionError) -> Set<String>
    func createDiscussion(
        repository: String,
        category: String,
        title: String,
        body: String
    ) async throws(DiscussionError) -> DiscussionSummary
    func updateDiscussion(_ id: String, title: String, body: String) async throws(DiscussionError)
    /// コメントを足して、その id を返す。`parent` があれば、そのコメントへの返信にする
    func addComment(to discussion: String, replyingTo parent: String?, body: String) async throws(DiscussionError) -> String
    func updateComment(_ id: String, body: String) async throws(DiscussionError)
    /// Discussion を閉じる。すでに閉じていても失敗しない
    func closeDiscussion(_ id: String, reason: DiscussionCloseReason) async throws(DiscussionError)
}

/// Discussion を閉じる理由（GraphQL の `DiscussionCloseReason`）
public enum DiscussionCloseReason: String, Equatable, Sendable {
    /// 解決済み（epic をマージした）
    case resolved = "RESOLVED"
    /// 古い（epic をやめた）
    case outdated = "OUTDATED"
}

public struct DiscussionRepository: Equatable, Sendable {
    public struct Category: Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// GraphQL の node id
    public var id: String
    public var discussionsEnabled: Bool
    public var categories: [Category]

    public init(id: String, discussionsEnabled: Bool, categories: [Category]) {
        self.id = id
        self.discussionsEnabled = discussionsEnabled
        self.categories = categories
    }
}

/// コメントか返信
public struct DiscussionPost: Equatable, Sendable {
    /// GraphQL の node id
    public var id: String
    public var body: String
    /// このトークンのアカウントが書いたか。写しは自分が書いたものだけを読む（public のリポジトリでは誰でも書ける）
    public var viewerDidAuthor: Bool

    public init(id: String, body: String, viewerDidAuthor: Bool) {
        self.id = id
        self.body = body
        self.viewerDidAuthor = viewerDidAuthor
    }
}

/// Discussion の一覧の 1 件（作った Discussion を目印で探すときに使う）
public struct DiscussionSummary: Equatable, Sendable {
    public var id: String
    public var number: Int
    public var body: String
    public var viewerDidAuthor: Bool
    public var createdAt: Date

    public init(id: String, number: Int, body: String, viewerDidAuthor: Bool, createdAt: Date) {
        self.id = id
        self.number = number
        self.body = body
        self.viewerDidAuthor = viewerDidAuthor
        self.createdAt = createdAt
    }
}

/// Discussion と、そのコメント（返信を含む）
public struct DiscussionThread: Equatable, Sendable {
    public struct Comment: Equatable, Sendable {
        public var post: DiscussionPost
        public var replies: [DiscussionPost]

        public init(post: DiscussionPost, replies: [DiscussionPost] = []) {
            self.post = post
            self.replies = replies
        }
    }

    public var id: String
    public var number: Int
    public var title: String
    public var body: String
    public var viewerDidAuthor: Bool
    /// 閉じているか
    public var closed: Bool
    public var comments: [Comment]

    public init(
        id: String,
        number: Int,
        title: String,
        body: String,
        viewerDidAuthor: Bool,
        closed: Bool = false,
        comments: [Comment] = []
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.viewerDidAuthor = viewerDidAuthor
        self.closed = closed
        self.comments = comments
    }
}

/// Discussion の写しを読み書きできなかった理由。トークンの値は含めない
public enum DiscussionError: Error, Equatable, Sendable {
    /// HTTP の失敗（上限・障害・認証・権限）と、書き込みの予算
    case http(StateStoreError)
    /// GraphQL の `errors`（`type` は `FORBIDDEN`・`NOT_FOUND` など。上限の `RATE_LIMITED` は `http` にする）
    case graphQL(type: String?, message: String)
    /// 写しを書けない設定（Discussions が無効・カテゴリが無い）。人がリポジトリの設定を直す
    case unavailable(String)
    /// 応答の形が想定と違う、または照らし合わせに使えない
    case malformed(String)

    /// 失敗の区分（試行と同じ区分で、やり直すまでの間を決める）
    public func attemptFailure(now: Date) -> AttemptFailure {
        switch self {
        case let .http(error):
            Self.attemptFailure(of: error, now: now)
        case let .graphQL(type, message):
            AttemptFailure(
                failureClass: .unexpected,
                message: "GitHub の GraphQL が断った（\(type ?? "種類なし")。トークンに Discussions の読み書きの権限が要る）: \(message)"
            )
        case let .unavailable(reason):
            AttemptFailure(failureClass: .unexpected, message: reason)
        case let .malformed(detail):
            AttemptFailure(failureClass: .githubOutage, message: "GitHub の応答を照らし合わせに使えない（\(detail)）")
        }
    }

    private static func attemptFailure(of error: StateStoreError, now: Date) -> AttemptFailure {
        switch error {
        case let .rateLimited(wait), let .budgetExhausted(wait):
            let retryAt = Timestamp(now.addingTimeInterval(TimeInterval(wait.components.seconds)))
            return AttemptFailure(failureClass: .githubOutage, message: "GitHub の上限・書き込みの予算に達した", retryAt: retryAt)
        case .cancelled:
            return AttemptFailure(failureClass: .macOffline, message: "司令塔を止めたので、写しを中断した")
        case .unauthorized, .tokenUnavailable:
            return AttemptFailure(failureClass: .authExpired, message: "GitHub のトークンが使えない")
        case .serverError, .transport:
            return AttemptFailure(failureClass: .githubOutage, message: "GitHub に届かない（\(error)）")
        case let .forbidden(message):
            return AttemptFailure(
                failureClass: .unexpected,
                message: "GitHub が断った（トークンに Discussions の読み書きの権限が要る）: \(message ?? "理由なし")"
            )
        default:
            return AttemptFailure(failureClass: .unexpected, message: "GitHub の Discussion を読み書きできない（\(error)）")
        }
    }
}
