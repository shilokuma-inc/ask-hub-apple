import AskHubProtocol
import AskHubPullRequests
import Foundation

/// CodeRabbit のレビューの様子（head のコミットの check run `CodeRabbit`。以前の CodeRabbit は commit status `CodeRabbit`）。
///
/// CodeRabbit は、上限での見送り・見送りを見出し（check run の `output.title`・commit status の `description`）の文言でも分ける（LEARNINGS.md）
enum CodeRabbitReview: Equatable {
    /// check run も commit status もまだ無い（始まっていない・入っていない）
    case notStarted
    case inProgress
    case completed
    /// 上限で見送った（"Review rate limited"・"Review limit reached"）。上限が戻っても自動ではレビューされない
    case rateLimited
    /// 見送った（"Review skipped"）
    case skipped
    /// 失敗した（check run の `failure` など・commit status の `error`・`failure`）
    case failed
    /// 終わったが、知らない結果・文言
    case unknown

    static let context = "CodeRabbit"

    /// CodeRabbit の check run があればそれで、無ければ commit status で決める
    init(runs: [CheckRunStatus], statuses: [CommitStatus]) {
        if let run = runs.first(where: { $0.name == Self.context && $0.app.map(Self.isAccount) == true }) {
            self.init(run)
        } else {
            self.init(statuses)
        }
    }

    init(_ run: CheckRunStatus) {
        guard run.status == "completed" else {
            self = .inProgress
            return
        }
        if let skipped = Self.skippedReview(run.title ?? "") {
            self = skipped
            return
        }
        switch run.conclusion {
        case "success":
            self = .completed
        case "skipped":
            self = .skipped
        case "failure", "timed_out", "cancelled", "action_required", "stale":
            self = .failed
        default:
            self = .unknown
        }
    }

    init(_ statuses: [CommitStatus]) {
        guard let status = statuses.first(where: { $0.context == Self.context }) else {
            self = .notStarted
            return
        }
        let description = status.description ?? ""
        switch status.state {
        case "pending":
            self = .inProgress
        case "success":
            self = Self.skippedReview(description) ?? (description.lowercased().contains("completed") ? .completed : .unknown)
        default:
            self = .failed
        }
    }

    /// 見出しの文言から、上限で見送った・見送ったを読む。どちらでもなければ nil
    static func skippedReview(_ text: String) -> CodeRabbitReview? {
        let text = text.lowercased()
        if text.contains("rate limit") || text.contains("limit reached") { return .rateLimited }
        return text.contains("skipped") ? .skipped : nil
    }

    /// CodeRabbit のアカウントか（REST の `coderabbitai[bot]` と GraphQL の `coderabbitai`）
    static func isAccount(_ login: String) -> Bool {
        login.lowercased().hasPrefix("coderabbitai")
    }
}

extension ReviewFinalPullRequestRunner {
    /// 信用するレビューの書き手のレビューを待つ。
    ///
    /// 待つ目印があるのは CodeRabbit（check run・commit status）だけなので、ほかの書き手は待たずに、今ある指摘を読む。
    /// CodeRabbit が上限で見送った・見送った・失敗したら待たない（ユーザーの決定）。始まらない・終わらないときも、上限まで待ったら進める
    func waitForReviewers(_ pulls: any PullRequestOperations, head: String, trusted: [String]) async throws(TaskJobExit) {
        guard trusted.contains(where: CodeRabbitReview.isAccount) else { return }
        let timing = environment.timing
        let started = environment.context.now()
        while true {
            let review = try await codeRabbitReview(pulls, head: head)
            let waited = environment.context.now().timeIntervalSince(started)
            guard let wait = Self.reviewerWait(review, waited: waited, timing: timing) else { return }
            do {
                try await environment.tasks.sleeper.sleep(for: wait)
            } catch {
                throw .fail(.macOffline, "ワーカーを止めたので、最終 PR のレビューを待つのをやめた")
            }
        }
    }

    /// CodeRabbit のレビューの様子を読む。check run が無いときだけ、以前の CodeRabbit の commit status を読む
    func codeRabbitReview(_ pulls: any PullRequestOperations, head: String) async throws(TaskJobExit) -> CodeRabbitReview {
        let runs = try await environment.tasks.github("最終 PR のレビューの様子を読む") { () throws(PullRequestError) in
            try await pulls.checkRuns(at: head)
        }
        let review = CodeRabbitReview(runs: runs, statuses: [])
        guard review == .notStarted else { return review }
        let statuses = try await environment.tasks.github("最終 PR のレビューの様子を読む") { () throws(PullRequestError) in
            try await pulls.commitStatuses(at: head)
        }
        return CodeRabbitReview(statuses)
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
