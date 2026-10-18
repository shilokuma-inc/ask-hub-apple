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

    /// オーケストレーターが書いた第三者レビューの進み具合。CodeRabbit が今の head をレビューしたら、
    /// オーケストレーターが状態コメントを書き換える前でも「済み（CodeRabbit）」と出す（Q2。第三者レビュー・修正はやめるため）
    static func progress(_ marker: FinalReviewMarker, codeRabbit: EpicPullRequest.CodeRabbitState) -> String {
        if codeRabbit == .completed {
            return FinalReviewMarker(state: .doneCodeRabbit, sha: marker.sha, attempts: marker.attempts).progressText
        }
        return marker.progressText
    }
}
