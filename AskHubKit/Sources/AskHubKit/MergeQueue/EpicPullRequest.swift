import Foundation

/// アプリの「マージ待ち」に出す、epic → develop の最終 PR（`epic-final`。Discussion #1 の Q13）
public struct EpicPullRequest: Sendable, Equatable, Hashable, Identifiable {
    /// CI の状態。最新コミットの **GitHub Actions の check run だけ**から決める（Discussion #460）。
    /// CodeRabbit などの commit status は含めない（処理中のまま止まることがあるため。CodeRabbit は `isReviewed` で別に見る）
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
    /// 完了（`completed`）だけが最終 PR のレビューの条件（`isReviewed`）を満たす（Discussion #503）。処理中・レート制限・スキップ・失敗・不明は満たさない
    public enum CodeRabbitState: String, Sendable, Equatable, Hashable {
        /// 処理中（レビュー中。commit status が `PENDING` か `EXPECTED`）
        case inProgress
        /// 完了（レビュー済み）
        case completed
        /// レート制限（無料枠の上限で止まった。"Review rate limited"）
        case rateLimited
        /// スキップ（レビューしなかった。"Review skipped" や "Review skipped: reviews are disabled for this base branch"）
        case skipped
        /// 失敗（commit status が `ERROR` / `FAILURE`）
        case failed
        /// `SUCCESS` だが `description` が無い・知らない文言（CodeRabbit が文言を変えたときなど）。完了とはみなさない
        case unknown
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

    /// TestFlight へのアップロード（Upload ワークフロー）の状況（Discussion #449 の Q4）
    public enum UploadStatus: Sendable, Equatable, Hashable {
        /// まだ読んでいない（run の取得を行わない構成）
        case notLoaded
        /// ワークフローが無い・リポジトリが見えない（404）。ボタンを出さない
        case unsupported
        /// ワークフローはあるが、この epic ブランチの run がまだ無い
        case noRuns
        /// 直近の run
        case run(UploadWorkflowRun)
        /// トークンに Actions の権限が無い（レート制限ではない 403）
        case permissionDenied
        /// run を取得できなかった（通信・レート制限など）。マージ待ちそのものは出す
        case unavailable

        /// 直近の run（無ければ `nil`）
        public var run: UploadWorkflowRun? {
            if case .run(let run) = self {
                return run
            }
            return nil
        }

        /// 「TestFlight に上げる」を出すか。ワークフローが無い（404）リポジトリでは出さない
        public var showsUploadButton: Bool {
            self != .unsupported
        }
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
    /// CodeRabbit の状態。完了なら今の head はレビュー済み（`isReviewed`）
    public var codeRabbit: CodeRabbitState
    /// Upload ワークフローの直近の run の状況。既定は `notLoaded`
    public var uploadStatus: UploadStatus
    /// 今の head（`headSHA`）に対する第三者レビューの目印。信用する author のコメントのうち最新のもの。無ければ `nil`
    public var thirdPartyReview: ThirdPartyReviewMarker?
    /// 今の head（`headSHA`）に対する第三者レビューの進み具合（オーケストレーターの状態コメント）。信用する author のコメントのうち最新のもの。無ければ `nil`
    public var finalReview: FinalReviewMarker?

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
        codeRabbit: CodeRabbitState = .none,
        uploadStatus: UploadStatus = .notLoaded,
        thirdPartyReview: ThirdPartyReviewMarker? = nil,
        finalReview: FinalReviewMarker? = nil
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
        self.uploadStatus = uploadStatus
        self.thirdPartyReview = thirdPartyReview
        self.finalReview = finalReview
    }

    /// マージボタンを押せるか。GitHub Actions の CI が成功していて、コンフリクトしていなくて（Q13・Discussion #460）、
    /// 今の head がレビュー済みであること（`isReviewed`。Discussion #503）
    public var canMerge: Bool {
        checks == .success && mergeability == .mergeable && isReviewed
    }

    /// 今の head がレビュー済みか。CodeRabbit のレビューが完了しているか、今の head の第三者レビューで要修正が 0 件（`must="0"`）なら済み（Discussion #503）。
    /// CodeRabbit のレート制限・スキップ・失敗・処理中は済みにしない。`thirdPartyReview` は信用する author が書いた今の head のものだけが入る
    public var isReviewed: Bool {
        codeRabbit == .completed || thirdPartyReview?.isClean == true
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
            reviewBlockingReason
        }
    }

    /// レビューの条件で押せない理由（レビュー済みなら `nil`）
    private var reviewBlockingReason: String? {
        if isReviewed {
            return nil
        }
        if let review = thirdPartyReview {
            return "第三者レビューで要修正が \(review.must) 件あります"
        }
        return "レビュー待ちです（CodeRabbit か第三者レビュー）"
    }

    /// 「TestFlight に上げる」を押せるか。CI（最新コミットのチェックのまとめ。マージボタンと同じ基準）が成功していて、
    /// 同じ epic ブランチで実行中の run が無いこと（Discussion #449 の Q3）。
    /// コンフリクトの有無は問わない（解消前でも実機で確かめられる）。起動した直後の判定は呼び出し側（アプリ）で持つ
    public var canUpload: Bool {
        uploadStatus.showsUploadButton && checks == .success && !(uploadStatus.run?.isRunning ?? false)
    }

    /// 「TestFlight に上げる」を押せない理由（押せるなら `nil`。ボタンを出さないときも `nil`）
    public var uploadBlockingReason: String? {
        guard uploadStatus.showsUploadButton else {
            return nil
        }
        if uploadStatus.run?.isRunning == true {
            return "同じ epic ブランチで Upload を実行中です"
        }
        switch checks {
        case .success:
            return nil

        case .failure:
            return "CI が失敗しています"

        case .pending:
            return "CI が終わっていません"

        case .none:
            return "CI が実行されていません"
        }
    }

    /// 直近の run がビルドしたコミットが、PR の最新の head と同じか（run が無ければ `nil`）
    public var uploadedLatestHead: Bool? {
        uploadStatus.run?.builtHead(headSHA)
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
