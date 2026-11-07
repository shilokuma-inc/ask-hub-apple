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
        // 前の試行がマージした後、記録する前に落ちた
        if pull.merged { return try await merged(input, sha: pull.mergeCommitSHA, target: target, pulls: pulls, claude: nil) }
        try Self.check(pull, against: input, branches: target.branches)
        let outputs = AttemptFile.Outputs(pullRequest: input.pullRequest, commit: input.head, branch: target.branches.task)
        if case let .failed(failures) = try await waitForChecks(pulls, head: input.head, required: target.settings.childChecks) {
            let findings = await ciFindings(failures, pulls: pulls)
            return JobResult(outputs: outputs.with(verdict: .fixCI, findings: findings))
        }
        let (result, session) = try await askReviewer(job, target: target, input: input)
        let claude = session.attemptRecord
        guard result.required.isEmpty else {
            let findings = FixTaskJob.Reason.review(result.findings).findings
            return JobResult(outputs: outputs.with(verdict: .fixReview, findings: findings), claude: claude)
        }
        let merge = try await environment.github("子 PR をマージする", keeping: JobResult(claude: claude)) { () throws(PullRequestError) in
            try await pulls.merge(number: input.pullRequest, headSHA: input.head, commitTitle: nil, commitMessage: nil)
        }
        return try await merged(input, sha: merge.sha, target: target, pulls: pulls, claude: claude)
    }

    /// 子 PR が、見る head のまま開いていて、子ブランチから作業ブランチに向いているか
    static func check(_ pull: PullRequest, against input: PullRequestInput, branches: TaskBranches) throws(TaskJobExit) {
        guard pull.state == .open else { throw .fail(.unexpected, "子 PR #\(pull.number) が、マージされずに閉じられた") }
        guard pull.headRef == branches.task, pull.baseRef == branches.epic else {
            throw .fail(.unexpected, "子 PR #\(pull.number) の向き（\(pull.headRef) → \(pull.baseRef)）が、タスクの子ブランチから作業ブランチへの向きでない")
        }
        guard pull.headSHA == input.head else {
            throw .fail(.unexpected, "子 PR #\(pull.number) の head が、見る head（\(input.head)）から動いた（\(pull.headSHA)）")
        }
    }

    /// 子 PR の head を取り出し、レビュー役の Claude に必須の指摘を聞く
    private func askReviewer(
        _ job: JobFile,
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
        let request = TaskReview.request(for: subject, repository: job.repo)
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
            // マージは済んでいるので、残った子ブランチは epic の片付けで消す
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
