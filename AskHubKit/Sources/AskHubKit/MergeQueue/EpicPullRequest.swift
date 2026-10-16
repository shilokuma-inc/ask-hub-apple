import Foundation

/// アプリの「マージ待ち」に出す、epic → develop の最終 PR（`epic-final`。Discussion #1 の Q13）
public struct EpicPullRequest: Sendable, Equatable, Hashable, Identifiable {
    /// CI の状態。最新コミットの **GitHub Actions の check run だけ**から決める（Discussion #460）。
    /// CodeRabbit などの commit status は含めない（処理中のまま止まることがあり、マージ条件にしない）
    public enum ChecksState: String, Sendable, Equatable, Hashable {
        /// GitHub Actions の check run がすべて成功（NEUTRAL / SKIPPED を含む）
        case success
        /// 失敗は無いが、まだ終わっていない check run がある
        case pending
        /// 失敗（TIMED_OUT / CANCELLED などを含む）した check run が 1 つでもある
        case failure
        /// GitHub Actions の check run が 1 つも無い
        case none
    }

    /// CodeRabbit のレビューの状態（commit status `CodeRabbit` から）。
    /// レビューを見てからマージしたい人のための**情報**で、マージ条件（`canMerge`）には使わない（Discussion #460）
    public enum CodeRabbitState: String, Sendable, Equatable, Hashable {
        /// 処理中（レビュー中。commit status が `PENDING` か `EXPECTED`）
        case inProgress
        /// 完了（レビュー済み）
        case completed
        /// レート制限（無料枠の上限で止まった。"Review rate limited"）
        case rateLimited
        /// 失敗（commit status が `ERROR` / `FAILURE`）
        case failed
        /// commit status `CodeRabbit` が無い（知らない `state` のときも含む）
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
    /// CodeRabbit の状態。情報として出すだけで、マージできるかには関係しない
    public var codeRabbit: CodeRabbitState

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
        mergeability: Mergeability,
        codeRabbit: CodeRabbitState = .none
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
        self.codeRabbit = codeRabbit
    }

    /// マージボタンを押せるか。GitHub Actions の CI が成功していて、コンフリクトしていないこと（Q13・Discussion #460）。
    /// `codeRabbit` は見ない
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
    /// organization 全体の、`epic-final` が付いた open な PR
    func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest]
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
