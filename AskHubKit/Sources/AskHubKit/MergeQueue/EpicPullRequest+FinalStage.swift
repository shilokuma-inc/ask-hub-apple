import Foundation

extension EpicPullRequest {
    /// 最終 PR の段階。「要対応」タブのマージ待ちの件数と、ステータスタブの「完了」の出し分けで共有する（Discussion #808）
    public enum FinalStage: String, Sendable, Equatable, Hashable, CaseIterable {
        /// CI の結果がまだ出ていない（実行中の check run が残っている・`pending`・check run が 1 つも無い）
        case waitingForChecks
        /// check run がすべて終わり、失敗したものがある
        case checksFailed
        /// CI は成功したが、マージ先とコンフリクトしている
        case conflicting
        /// CI は成功し、コンフリクトも無いが、今の head がレビュー済みでない
        case waitingForReview
        /// CI が成功し、レビュー済みだが、コンフリクトの有無を GitHub が計算中（`mergeability == .unknown`）
        case checkingMergeability
        /// マージボタンを押せる（`canMerge`）
        case mergeable

        /// 一覧やステータスに出す短い文言
        public var label: String {
            switch self {
            case .waitingForChecks:
                "CI 待ち"

            case .checksFailed:
                "CI 失敗"

            case .conflicting:
                "コンフリクト"

            case .waitingForReview:
                "レビュー待ち"

            case .checkingMergeability:
                "マージ可否の確認中"

            case .mergeable:
                "マージ可"
            }
        }

        /// 異常として目立たせるか（CI 失敗・コンフリクト）
        public var isProblem: Bool {
            self == .checksFailed || self == .conflicting
        }

        /// 「要対応」のバッジとマージ待ちの見出しの件数に数えるか。マージ可と CI 失敗だけ（Discussion #808 の Q3）
        public var countsAsActionable: Bool {
            self == .mergeable || self == .checksFailed
        }
    }

    /// 最終 PR の段階。上から順に当てはめる。
    /// `checks` は失敗が 1 つでもあれば実行中の check run が残っていても `failure` になるので、`hasRunningChecks` を先に見る
    public var finalStage: FinalStage {
        if hasRunningChecks {
            return .waitingForChecks
        }
        switch checks {
        case .pending, .none:
            return .waitingForChecks

        case .failure:
            return .checksFailed

        case .success:
            break
        }
        if mergeability == .conflicting {
            return .conflicting
        }
        if !isReviewed {
            return .waitingForReview
        }
        return canMerge ? .mergeable : .checkingMergeability
    }

    /// 「要対応」に数えるか（`finalStage.countsAsActionable`）
    public var countsAsActionable: Bool {
        finalStage.countsAsActionable
    }
}
