import AskHubProtocol
import AskHubPullRequests
import Foundation

/// タスクの直し（`fixTask`）を 1 回実行する（`docs/renewal/flows.md` の「タスクの流れ」）。epic の Mac で動く。
///
/// 子 PR のレビュー（`reviewTask`）が書いた直すこと（`outputs.findings`）を付けて、実装の会話を再開して直させ、子ブランチに push する。
/// 直しの回数（3 回まで）は、司令塔が試行から数える
public struct FixTaskRunner: JobRunning {
    public var environment: TaskJobEnvironment

    public init(environment: TaskJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .fixTask) { target throws(TaskJobExit) in
            try await fix(job, target)
        }
    }

    private func fix(_ job: JobFile, _ target: TaskTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: FixTaskInput.self) else { throw .fail(.unexpected, "fixTask の入力（PR・head・理由）の形が違う") }
        let environment = environment
        let history = TaskHistory(context: environment.context, repo: job.repo, epic: job.epic)
        guard let findings = try await history.findings(for: input, task: target.task.id) else {
            throw .fail(.unexpected, "直すこと（子 PR #\(input.pullRequest) の head \(input.head) を見たレビューの結果）が見つからない")
        }
        guard let session = try await history.session(of: target.task.id) else {
            throw .fail(.unexpected, "タスク \(target.task.id) の実装の会話（implementTask の試行の claude.session）が見つからない")
        }
        let pull = try await environment.github("子 PR を読む") { () throws(PullRequestError) in
            try await environment.pullRequests(job.repo).pullRequest(number: input.pullRequest)
        }
        guard pull.state == .open, !pull.merged else { throw .fail(.unexpected, "子 PR #\(input.pullRequest) が開いていない") }
        try ReviewTaskRunner.checkDirection(pull, branches: target.branches)
        let checkout = try await environment.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutTask(job.repo, epic: job.epic, branches: target.branches)
        }
        var result = JobResult(outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, branch: target.branches.task))
        guard checkout.head == input.head else {
            // 前の試行が直して push した後、記録する前に落ちた。子ブランチが直す head から進んでいれば、その先頭を結果にする（直させ直さない）
            let advanced = try await environment.workspace { () throws(WorkspaceError) in
                try await environment.git.isAncestor(input.head, of: checkout.head, in: checkout)
            }
            guard advanced else {
                throw .fail(.unexpected, "子ブランチの先頭（\(checkout.head)）が、直す head（\(input.head)）から続いていない")
            }
            result.outputs?.commit = checkout.head
            return result
        }
        let fixJob = FixTaskJob(session: session, pullRequest: input.pullRequest, reason: input.reason, findings: findings)
        let (report, run) = try await environment.run(fixJob, in: checkout, target: target).done()
        result.outputs?.report = report.outputReport
        result.claude = run.session?.attemptRecord
        let message = Self.commitMessage(task: target.task, reason: input.reason, report: report)
        let pushed = try await environment.workspace(keeping: result) { () throws(WorkspaceError) in
            try await environment.git.commitAndPush(checkout, message: message)
        }
        // 何も変えなかった（指摘が誤っていると判断した）ときは、同じ head のまま、もう一度レビューを受ける
        result.outputs?.commit = pushed ?? checkout.head
        return result
    }

    static func commitMessage(task: GoalFile.Task, reason: FixTaskInput.Reason, report: TaskReport) -> String {
        let what = reason == .ci ? "CI の失敗" : "レビューの指摘"
        return "\(task.title)（\(what)を直す）\n\n\(UntrustedText.head(report.summary, limit: 4_000))\n\nAskHub のタスク \(task.id)"
    }
}
