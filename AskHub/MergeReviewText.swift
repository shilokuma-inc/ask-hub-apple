import AskHubKit

/// 最終 PR の詳細に出す、レビューの状態の文言（Discussion #503）
enum MergeReviewText {
    /// 今の head をレビュー済みにしたもの。CodeRabbit の完了を先に見る（完了なら第三者レビューはやめる。Q2）
    static func source(_ pullRequest: EpicPullRequest) -> String {
        if pullRequest.codeRabbit == .completed {
            return "CodeRabbit"
        }
        if let review = pullRequest.thirdPartyReview {
            return "第三者（要修正 \(review.must)・提案 \(review.may)）"
        }
        return "まだありません"
    }

    /// オーケストレーターが書いた第三者レビューの進み具合
    static func progress(_ marker: FinalReviewMarker) -> String {
        switch marker.state {
        case .waiting:
            "CodeRabbit を待っています"

        case .reviewing:
            "レビュー中"

        case .fixing:
            marker.attempts > 0 ? "修正中（\(marker.attempts) 回目）" : "修正中"

        case .done:
            "済み"

        case .doneCodeRabbit:
            "済み（CodeRabbit）"

        case .gaveUp:
            "あきらめました（要修正が \(marker.attempts) 回続きました）"
        }
    }
}
