import AskHubClaude
import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 子 PR のレビュー（`reviewTask`）を 1 回実行する（`docs/renewal/flows.md` の「タスクの流れ」）。epic の Mac で動く。
///
/// 1. 子 PR で待つチェック（`repo.json` の `build.childChecks`）を待つ（`ReviewTaskRunner+Checks.swift`）。落ちたら `fixCI`
/// 2. 通ったら、読むだけのレビュー役の Claude が差分を読み、必須の指摘を返す。あれば `fixReview`
/// 3. 無ければ、見た head を固定して merge commit でマージし、子ブランチを消して `merged`
///
/// 待つ間・レビューの間に push された変更はマージしない（`input.head` を固定する）
public struct ReviewTaskRunner: JobRunning {
    public var environment: TaskJobEnvironment
    public var timing: ReviewTiming

    public init(environment: TaskJobEnvironment, timing: ReviewTiming = ReviewTiming()) {
        self.environment = environment
        self.timing = timing
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .reviewTask) { target throws(TaskJobExit) in
            try await review(job, target)
        }
    }

    private func review(_ job: JobFile, _ target: TaskTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: PullRequestInput.self) else { throw .fail(.unexpected, "reviewTask の入力（PR と head）の形が違う") }
        let pulls = environment.pullRequests(job.repo)
        let pull = try await environment.github("子 PR を読む") { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        // 前の試行がマージした後、記録する前に落ちた（見る head を子ブランチから作業ブランチへマージしたものだけを、終わったとみなす）
        if pull.merged {
            try Self.checkDirection(pull, branches: target.branches)
            try Self.checkHead(pull, against: input)
            return try await merged(input, sha: pull.mergeCommitSHA, target: target, pulls: pulls, claude: nil)
        }
        try Self.check(pull, against: input, branches: target.branches)
        let outputs = AttemptFile.Outputs(pullRequest: input.pullRequest, commit: input.head, branch: target.branches.task)
        let waited = try await waitForChecks(pulls, pullRequest: input.pullRequest, head: input.head, required: target.settings.childChecks)
        if case let .failed(failures) = waited {
            let findings = await ciFindings(failures, pulls: pulls)
            return JobResult(outputs: outputs.with(verdict: .fixCI, findings: findings))
        }
        let (result, session) = try await askReviewer(job, target: target, input: input)
        let claude = session.attemptRecord
        guard result.required.isEmpty else {
            let findings = FixTaskJob.Reason.review(result.findings).findings
            return JobResult(outputs: outputs.with(verdict: .fixReview, findings: findings), claude: claude)
        }
        // マージの API は向き先を固定できないので、待つ間・レビューの間に向き先や head が変わっていないかを、マージの直前に確かめ直す
        let current = try await environment.github("子 PR を読む", keeping: JobResult(claude: claude)) { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        try Self.check(current, against: input, branches: target.branches, keeping: JobResult(claude: claude))
        let merge = try await environment.github("子 PR をマージする", keeping: JobResult(claude: claude)) { () throws(PullRequestError) in
            try await pulls.merge(number: input.pullRequest, headSHA: input.head, commitTitle: nil, commitMessage: nil)
        }
        // 読み直してからマージするまでの間に向き先が変えられていたら、作業ブランチ以外に入っている。取り消せないので、merged とせずに人へ渡す
        let landed = try await environment.github("マージした子 PR を読む", keeping: JobResult(claude: claude)) { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        guard landed.baseRef == target.branches.epic else {
            let message = "子 PR #\(input.pullRequest) が、作業ブランチ（\(target.branches.epic)）ではなく \(landed.baseRef) にマージされた。人が確かめる"
            throw .fail(.unexpected, message, keeping: JobResult(claude: claude))
        }
        return try await merged(input, sha: merge.sha, target: target, pulls: pulls, claude: claude)
    }

    /// 子 PR が、見る head のまま開いていて、子ブランチから作業ブランチに向いているか
    static func check(
        _ pull: PullRequest,
        against input: PullRequestInput,
        branches: TaskBranches,
        keeping partial: JobResult = JobResult()
    ) throws(TaskJobExit) {
        guard pull.state == .open, !pull.merged else {
            throw .fail(.unexpected, "子 PR #\(pull.number) が開いていない", keeping: partial)
        }
        try checkDirection(pull, branches: branches, keeping: partial)
        try checkHead(pull, against: input, keeping: partial)
    }

    /// 子 PR が、タスクの子ブランチから作業ブランチに向いているか（入力の PR の番号の取り違えで、ほかの PR を扱わない）
    static func checkDirection(_ pull: PullRequest, branches: TaskBranches, keeping partial: JobResult = JobResult()) throws(TaskJobExit) {
        guard pull.headRef == branches.task, pull.baseRef == branches.epic else {
            let message = "子 PR #\(pull.number) の向き（\(pull.headRef) → \(pull.baseRef)）が、タスクの子ブランチから作業ブランチへの向きでない"
            throw .fail(.unexpected, message, keeping: partial)
        }
    }

    static func checkHead(
        _ pull: PullRequest,
        against input: PullRequestInput,
        keeping partial: JobResult = JobResult()
    ) throws(TaskJobExit) {
        guard pull.headSHA == input.head else {
            throw .fail(.unexpected, "子 PR #\(pull.number) の head が、見る head（\(input.head)）から動いた（\(pull.headSHA)）", keeping: partial)
        }
    }

    /// 子 PR の head を取り出し、レビュー役の Claude に必須の指摘を聞く
    private func askReviewer(
        _ job: JobFile,
        target: TaskTarget,
        input: PullRequestInput
    ) async throws(TaskJobExit) -> (result: TaskReviewResult, session: ClaudeSession) {
        let environment = environment
        // 取り出してからレビュー役が読み終えるまで、epic の作業場所をほかのジョブに使わせない（チェックを待つ間は使わない）
        return try await environment.exclusively(job.epic) { () throws(TaskJobExit) in
            try await askReviewer(in: job, target: target, input: input)
        }
    }

    private func askReviewer(
        in job: JobFile,
        target: TaskTarget,
        input: PullRequestInput
    ) async throws(TaskJobExit) -> (result: TaskReviewResult, session: ClaudeSession) {
        let environment = environment
        let checkout = try await environment.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutReview(job.repo, epic: job.epic, branches: target.branches, head: input.head)
        }
        let subject = TaskReview.Subject(
            goal: target.goal,
            task: target.task,
            pullRequest: input.pullRequest,
            head: input.head,
            branches: target.branches,
            checkout: checkout
        )
        guard let request = TaskReview.request(for: subject, repository: job.repo) else {
            let limit = TaskReview.maximumTextBytes
            let message = "ゴールとこのタスクの文が長すぎて、差分をレビュー役の Claude に渡せない（決まりの文と合わせて UTF-8 で \(limit) バイトまで）"
            throw .fail(.unexpected, message)
        }
        switch await environment.reviewer.ask(request, as: TaskReviewResult.self, now: environment.context.now, check: { $0.problems }) {
        case let .answered(result, session):
            return (result, session)
        case let .failed(failure, session):
            throw .finish(JobResult(failure: failure, claude: session?.attemptRecord))
        }
    }

    /// マージした子 PR の子ブランチを消して、`merged` で終える。消す前に子ブランチへ push されていたら、消さずに残す
    private func merged(
        _ input: PullRequestInput,
        sha: String?,
        target: TaskTarget,
        pulls: any PullRequestOperations,
        claude: AttemptFile.Claude?
    ) async throws(TaskJobExit) -> JobResult {
        do {
            _ = try await pulls.deleteBranch(target.branches.task, expectedSHA: input.head)
        } catch .headChanged {
            // マージは済んでいる。マージの後に push されたものは失わないよう、子ブランチは消さずに残す（要らなければ人が GitHub で消す）
        } catch {
            throw .finish(JobResult(failure: error.attemptFailure(doing: "マージした子ブランチを消す", now: environment.context.now()), claude: claude))
        }
        let commit = sha ?? input.head
        return JobResult(
            outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, commit: commit, branch: target.branches.task, verdict: .merged),
            claude: claude
        )
    }
}

extension AttemptFile.Outputs {
    func with(verdict: ReviewVerdict, findings: String) -> Self {
        var outputs = self
        outputs.verdict = verdict
        outputs.findings = findings
        return outputs
    }
}
