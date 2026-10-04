import Foundation

/// アプリの「マージ待ち」に出す、epic → develop の最終 PR（`epic-final`。Discussion #1 の Q13）
public struct EpicPullRequest: Sendable, Equatable, Hashable, Identifiable {
    /// CI（最新コミットのチェック）の状態
    public enum ChecksState: String, Sendable, Equatable, Hashable {
        case success
        case pending
        case failure
        /// チェックが 1 つも無い
        case none
    }

    /// コンフリクトの有無
    public enum Mergeability: String, Sendable, Equatable, Hashable {
        case mergeable
        case conflicting
        /// GitHub がまだ計算していない
        case unknown
    }

    /// GraphQL の node id
    public var id: String
    /// `owner/repo`
    public var repository: String
    public var number: Int
    public var title: String
    /// 本文（オーケストレーターが入れた「最終 PR に載せる内容」）
    public var body: String
    public var url: URL
    /// マージ先（develop）
    public var baseBranch: String
    /// epic ブランチ
    public var headBranch: String
    /// マージする head のコミット。確認した後に PR が更新されていたらマージしないために使う
    public var headSHA: String
    /// 削除済みのユーザーでは `nil`
    public var author: String?
    public var checks: ChecksState
    public var mergeability: Mergeability

    public init(
        id: String,
        repository: String,
        number: Int,
        title: String,
        body: String,
        url: URL,
        baseBranch: String,
        headBranch: String,
        headSHA: String,
        author: String?,
        checks: ChecksState,
        mergeability: Mergeability
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.author = author
        self.checks = checks
        self.mergeability = mergeability
    }

    /// マージボタンを押せるか。CI が成功していて、コンフリクトしていないこと（Q13）
    public var canMerge: Bool {
        checks == .success && mergeability == .mergeable
    }

    /// 押せない理由（押せるなら `nil`）
    public var blockingReason: String? {
        switch (checks, mergeability) {
        case (_, .conflicting):
            "\(baseBranch) とコンフリクトしています"

        case (.failure, _):
            "CI が失敗しています"

        case (.pending, _):
            "CI が終わっていません"

        case (.none, _):
            "CI が実行されていません"

        case (.success, .unknown):
            "マージできるかを GitHub が確認中です。少し待ってから更新してください"

        case (.success, .mergeable):
            nil
        }
    }

    /// 差分の URL
    public var filesURL: URL {
        url.appending(path: "files")
    }
}

/// 「マージ待ち」の取得とマージ。テストでは差し替える
public protocol MergeQueueProviding: Sendable {
    /// org 全体の、`epic-final` が付いた open な PR
    func epicPullRequests(org: String) async throws -> [EpicPullRequest]
    /// merge commit でマージし、epic ブランチを削除する
    func merge(_ pullRequest: EpicPullRequest) async throws
}

/// マージできないときのエラー
public enum MergeQueueError: Error, Equatable, Sendable {
    /// CI が成功していない、またはコンフリクトしている
    case notMergeable(reason: String)
    /// マージはできたが、epic ブランチを削除できなかった
    case branchNotDeleted(String)
}
