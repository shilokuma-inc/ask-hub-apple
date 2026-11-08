import AskHubProtocol
import AskHubPullRequests
import Foundation

/// CodeRabbit のレビューの様子（head のコミットの commit status `CodeRabbit`）。
///
/// CodeRabbit は、完了・上限での見送り・見送りを、どれも `success` の説明の文言だけで分ける（LEARNINGS.md）
enum CodeRabbitReview: Equatable {
    /// commit status がまだ無い（始まっていない・入っていない）
    case notStarted
    case inProgress
    case completed
    /// 上限で見送った（"Review rate limited"・"Review limit reached"）。上限が戻っても自動ではレビューされない
    case rateLimited
    /// 見送った（"Review skipped"）
    case skipped
    /// 失敗した（`error`・`failure`）
    case failed
    /// `success` だが、知らない文言
    case unknown

    static let context = "CodeRabbit"

    init(_ statuses: [CommitStatus]) {
        guard let status = statuses.first(where: { $0.context == Self.context }) else {
            self = .notStarted
            return
        }
        let description = status.description?.lowercased() ?? ""
        switch status.state {
        case "pending":
            self = .inProgress
        case "success":
            if description.contains("rate limit") || description.contains("limit reached") {
                self = .rateLimited
            } else if description.contains("skipped") {
                self = .skipped
            } else {
                self = description.contains("completed") ? .completed : .unknown
            }
        default:
            self = .failed
        }
    }

    /// CodeRabbit のアカウントか（REST の `coderabbitai[bot]` と GraphQL の `coderabbitai`）
    static func isAccount(_ login: String) -> Bool {
        login.lowercased().hasPrefix("coderabbitai")
    }
}

extension ReviewFinalPullRequestRunner {
    /// 信用するレビューの書き手のレビューを待つ。
    ///
    /// 待つ目印があるのは CodeRabbit（commit status）だけなので、ほかの書き手は待たずに、今ある指摘を読む。
    /// CodeRabbit が上限で見送った・見送った・失敗したら待たない（ユーザーの決定）。始まらない・終わらないときも、上限まで待ったら進める
    func waitForReviewers(_ pulls: any PullRequestOperations, head: String, trusted: [String]) async throws(TaskJobExit) {
        guard trusted.contains(where: CodeRabbitReview.isAccount) else { return }
        let timing = environment.timing
        let started = environment.context.now()
        while true {
            let statuses = try await environment.tasks.github("最終 PR のレビューの様子を読む") { () throws(PullRequestError) in
                try await pulls.commitStatuses(at: head)
            }
            let waited = environment.context.now().timeIntervalSince(started)
            guard let wait = Self.reviewerWait(CodeRabbitReview(statuses), waited: waited, timing: timing) else { return }
            do {
                try await environment.tasks.sleeper.sleep(for: wait)
            } catch {
                throw .fail(.macOffline, "ワーカーを止めたので、最終 PR のレビューを待つのをやめた")
            }
        }
    }

    /// 次に待つ時間。待たずに進めるなら nil
    static func reviewerWait(_ review: CodeRabbitReview, waited: TimeInterval, timing: FinalReviewTiming) -> Duration? {
        switch review {
        case .notStarted:
            waited < TaskRunner.seconds(timing.reviewerStartLimit) ? timing.reviewerPoll : nil
        case .inProgress:
            waited < TaskRunner.seconds(timing.reviewerLimit) ? timing.reviewerPoll : nil
        case .completed, .rateLimited, .skipped, .failed, .unknown:
            nil
        }
    }

    /// 信用する書き手の、未解決の行コメントとレビューの本文。信用する書き手が無ければ読まない。
    ///
    /// public のリポジトリでは誰でもコメントできるので、GitHub の部品が絞ったものを、ここでも信用する書き手のものだけに絞り直す
    /// （起点が信用しない書き手のスレッドと、信用しない書き手の返信を渡さない）
    func trustedFeedback(_ pulls: any PullRequestOperations, number: Int, trusted: [String]) async throws(TaskJobExit) -> ReviewFeedback {
        guard !trusted.isEmpty else { return ReviewFeedback(threads: [], reviews: []) }
        let authors = TrustedAuthors(trusted)
        let feedback = try await environment.tasks.github("最終 PR のレビューの指摘を読む") { () throws(PullRequestError) in
            try await pulls.reviewFeedback(number: number, trusted: authors)
        }
        let isTrusted = { (login: String) in authors.logins.contains(login.lowercased()) }
        let threads = feedback.threads.compactMap { thread -> ReviewThread? in
            guard let root = thread.comments.first, isTrusted(root.author) else { return nil }
            var trustedThread = thread
            trustedThread.comments = thread.comments.filter { isTrusted($0.author) }
            return trustedThread
        }
        return ReviewFeedback(threads: threads, reviews: feedback.reviews.filter { isTrusted($0.author) })
    }
}
