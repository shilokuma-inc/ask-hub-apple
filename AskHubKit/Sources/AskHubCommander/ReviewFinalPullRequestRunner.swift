import AskHubClaude
import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR のレビュー（`reviewFinalPullRequest`）を 1 回実行する（`docs/renewal/flows.md` の「最終 PR までの段取り」）。常時オンの Mac で動く。
///
/// 1. 最終 PR で待つチェック（`repo.json` の `build.finalChecks`）を待つ（子 PR と同じ待ち方。揺らぎは 1 回だけ流し直す）。落ちたら `fixCI`
/// 2. 信用するレビューの書き手（`build.trustedReviewers`）のレビューを待つ（`ReviewFinalPullRequestRunner+Reviewers.swift`）。
///    CodeRabbit が上限で見送ったら待たない
/// 3. 読むだけのレビュー役の Claude が、epic 全体の差分と、信用する書き手の指摘（データとして囲む）を読み、必須の指摘とマージの規則の材料を返す。
///    必須の指摘があれば `fixReview`、無ければ `ready`。材料には、差分のパスから決まった規則で見つけたもの（`FinalMergeRisks`）も足す
///
/// 待つ間・レビューの間に head が進んだら、古い head の判定を書かない（`verdict` を書かずに、今の head だけを書いて成功で終える）。
/// マージはしない（マージの規則と人の承認で、司令塔が `mergeFinalPullRequest` を作る）
public struct ReviewFinalPullRequestRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .reviewFinalPullRequest) { target throws(TaskJobExit) in
            try await review(job, target)
        }
    }

    private func review(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: PullRequestInput.self) else {
            throw .fail(.unexpected, "reviewFinalPullRequest の入力（PR と head）の形が違う")
        }
        let pulls = environment.tasks.pullRequests(job.repo)
        let outputs = AttemptFile.Outputs(pullRequest: input.pullRequest, commit: input.head)
        if let moved = try await movedHead(input, target: target, pulls: pulls) { return Self.stale(input, head: moved) }
        let checks = ReviewTaskRunner(environment: environment.tasks, timing: environment.timing.checks)
        let waited = try await checks.waitForChecks(pulls, head: input.head, required: target.settings.finalChecks, subject: .final)
        if case let .failed(failures) = waited {
            let findings = await checks.ciFindings(failures, pulls: pulls)
            if let moved = try await movedHead(input, target: target, pulls: pulls) { return Self.stale(input, head: moved) }
            return JobResult(outputs: outputs.with(verdict: .fixCI, findings: findings))
        }
        try await waitForReviewers(pulls, head: input.head, trusted: target.settings.trustedReviewers)
        if let moved = try await movedHead(input, target: target, pulls: pulls, conflicts: true) { return Self.stale(input, head: moved) }
        let feedback = try await trustedFeedback(pulls, number: input.pullRequest, trusted: target.settings.trustedReviewers)
        let (answer, checkout) = try await askReviewer(job, target: target, input: input, feedback: feedback)
        let claude = JobResult(claude: answer.session.attemptRecord)
        if let moved = try await movedHead(input, target: target, pulls: pulls, keeping: claude) {
            return Self.stale(input, head: moved, claude: claude.claude)
        }
        guard answer.result.required.isEmpty else {
            let findings = FixTaskJob.Reason.review(answer.result.findings).findings
            return JobResult(outputs: outputs.with(verdict: .fixReview, findings: findings), claude: claude.claude)
        }
        var ready = outputs
        ready.verdict = .ready
        ready.mergeRisks = FinalMergeRisks.merged(
            answer.result.mergeRisks,
            FinalMergeRisks.risks(paths: checkout.paths, projectLines: checkout.projectLines)
        )
        return JobResult(outputs: ready, claude: claude.claude)
    }

    /// head が進んだときの結果。古い head の判定は書かず、今の head だけを書く（司令塔は、新しい head でレビューし直せる）
    static func stale(_ input: PullRequestInput, head: String, claude: AttemptFile.Claude? = nil) -> JobResult {
        JobResult(outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, commit: head), claude: claude)
    }

    /// 最終 PR を読み直し、見る head から進んでいれば今の head を返す。開いていない・向きが違う・（`conflicts` なら）コンフリクトしていれば失敗で終える
    private func movedHead(
        _ input: PullRequestInput,
        target: FinalTarget,
        pulls: any PullRequestOperations,
        conflicts: Bool = false,
        keeping partial: JobResult = JobResult()
    ) async throws(TaskJobExit) -> String? {
        let pull = try await environment.tasks.github("最終 PR を読む", keeping: partial) { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        guard pull.state == .open, !pull.merged else {
            throw .fail(.unexpected, "最終 PR #\(input.pullRequest) が開いていない", keeping: partial)
        }
        try FinalJobEnvironment.checkDirection(pull, branches: target.branches, keeping: partial)
        guard pull.headSHA == input.head else { return pull.headSHA }
        // GitHub が計算中（nil）なら、コンフリクトとはみなさない（マージのときに GitHub が断る）
        if conflicts, pull.mergeable == false {
            let message = "最終 PR #\(input.pullRequest) が base（\(target.branches.base)）とコンフリクトしている"
            throw .fail(.conflict, message, keeping: partial)
        }
        return nil
    }

    /// 最終 PR の head をジョブのフォルダに取り出し、レビュー役の Claude に必須の指摘とマージの規則の材料を聞く
    private func askReviewer(
        _ job: JobFile,
        target: FinalTarget,
        input: PullRequestInput,
        feedback: ReviewFeedback
    ) async throws(TaskJobExit) -> (answer: (result: FinalReviewResult, session: ClaudeSession), checkout: FinalReviewCheckout) {
        let environment = environment
        return try await environment.withFinalCheckout(job, target: target, head: input.head) { checkout throws(TaskJobExit) in
            let subject = FinalReview.Subject(
                goal: target.goal,
                pullRequest: input.pullRequest,
                branches: target.branches,
                checkout: checkout,
                feedback: FinalReview.feedbackText(feedback)
            )
            guard let request = FinalReview.request(for: subject, repository: job.repo) else {
                let limit = TaskReview.maximumTextBytes
                let message = "ゴールの文が長すぎて、差分をレビュー役の Claude に渡せない（決まりの文と合わせて UTF-8 で \(limit) バイトまで）"
                throw .fail(.unexpected, message)
            }
            let answer = try await environment.ask(request, as: FinalReviewResult.self) { $0.problems }
            return (answer, checkout)
        }
    }
}
