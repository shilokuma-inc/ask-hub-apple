import AskHubKit
import Foundation

// 最終 PR の第三者レビューの進み具合を、PR に目印付きの状態コメント 1 件として書き出し、変わったら書き換える
// （`docs/protocol.md` の「最終 PR の第三者レビューの進み具合」）。アプリはこの目印を読んで詳細画面に出す
extension Orchestrator {
    /// 追跡している最終 PR の進み具合を書き出す。前に書いた内容と同じなら何もしない。
    /// 状態コメントがまだ無い PR では、CodeRabbit を待っている間と、CodeRabbit がレビューした（済み（CodeRabbit））ときは作らない
    /// （CodeRabbit がレビューできる PR にコメントを増やさない）
    func publishFinalReviewStatuses() async {
        let current = Set(finalReviewCandidates.map(\.pullRequest.key))
        publishedFinalReviews = publishedFinalReviews.filter { current.contains($0.key) }
        finalReviewStatusComments = finalReviewStatusComments.filter { current.contains($0.key) }
        for candidate in finalReviewCandidates {
            let pullRequest = candidate.pullRequest
            guard let marker = finalReviewTracker.marker(for: pullRequest), publishedFinalReviews[pullRequest.key] != marker,
                  !publishingFinalReviews.contains(pullRequest.key) else {
                continue
            }
            publishingFinalReviews.insert(pullRequest.key)
            await publish(marker, for: pullRequest)
            publishingFinalReviews.remove(pullRequest.key)
        }
    }

    private func publish(_ marker: FinalReviewMarker, for pullRequest: FinalReviewPullRequest) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        guard let body = Self.statusBody(marker) else {
            return
        }
        do {
            if let id = try await statusCommentID(for: pullRequest) {
                try await github.updateComment(in: pullRequest.repository, id: id, body: body)
            } else if [.waiting, .doneCodeRabbit].contains(marker.state) {
                // まだ第三者レビューに関わっていないので、コメントを作らない
            } else {
                let id = try await github.createComment(onPullRequest: pullRequest.number, in: pullRequest.repository, body: body)
                finalReviewStatusComments[pullRequest.key] = id
            }
            publishedFinalReviews[pullRequest.key] = marker
        } catch {
            // 次のポーリングで書き直す
            log("\(name) に第三者レビューの進み具合を書き出せませんでした: \(error)")
        }
    }

    /// その PR の状態コメントの id。覚えていなければ、信用する author が書いた目印付きのコメントのうち最後のものを探す
    /// （オーケストレーターを再起動した後も、前のコメントを書き換える）
    private func statusCommentID(for pullRequest: FinalReviewPullRequest) async throws -> Int? {
        if let id = finalReviewStatusComments[pullRequest.key] {
            return id
        }
        let authors = trust.authors(for: pullRequest.repository)
        let comments = try await github.comments(in: pullRequest.repository, issue: pullRequest.number)
        let id = comments.last { authors.contains($0.author) && FinalReviewMarker.parse($0.body) != nil }?.id
        finalReviewStatusComments[pullRequest.key] = id
        return id
    }

    /// 状態コメントの本文。先頭に目印を置き、人が読む説明を続ける
    static func statusBody(_ marker: FinalReviewMarker) -> String? {
        guard let comment = marker.htmlComment else {
            return nil
        }
        return """
            \(comment)
            ### 第三者レビューの進み具合: \(marker.progressText)

            対象の head: `\(marker.sha.prefix(7))`

            CodeRabbit がこの head をレビューできない（レート制限・失敗・スキップ、または 10 分経ってもレビューが付かない）ときは、
            askhub-orchestrator が第三者レビューをし、要修正があれば直して push します。要修正が 3 回続いたら自動の修正をやめます。
            このコメントは askhub-orchestrator が書き換えます。
            """
    }
}
