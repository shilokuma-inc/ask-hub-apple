import AskHubProtocol
import AskHubPullRequests
import Foundation

/// タスクの実装（`implementTask`）を 1 回実行する（`docs/renewal/flows.md` の「タスクの流れ」）。epic の Mac で動く。
///
/// 1. epic の作業場所に子ブランチを取り出す（リモートにあれば使う。前の試行が push した後に落ちても作り直さない）
/// 2. Claude に実装させる（ビルドとテストの往復は `TaskRunner`）
/// 3. `done` なら、ワーカーが commit・push し、作業ブランチ宛ての子 PR を作る（同じ head の開いた PR があれば作らない）
///
/// 人に聞きたいこと（`needsQuestion`）・進められない（`blocked`）・往復の使い切りは、今は理由を付けた失敗にして人へ渡す
public struct ImplementTaskRunner: JobRunning {
    public var environment: TaskJobEnvironment

    public init(environment: TaskJobEnvironment) {
        self.environment = environment
    }

    /// PR の本文に載せる、Claude の要約の長さの上限（文字数）
    static let maximumSummaryLength = 20_000

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .implementTask) { target throws(TaskJobExit) in
            try await implement(job, target)
        }
    }

    private func implement(_ job: JobFile, _ target: TaskTarget) async throws(TaskJobExit) -> JobResult {
        let environment = environment
        let checkout = try await environment.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutTask(job.repo, epic: job.epic, branches: target.branches)
        }
        let history = TaskHistory(context: environment.context, repo: job.repo, epic: job.epic)
        let previous = try await history.previousTasks(in: target.goal, before: target.task.id)
        let implement = ImplementTaskJob(goal: target.goal, task: target.task, previous: previous)
        let (report, run) = try await environment.run(implement, in: checkout, target: target).done()
        var result = JobResult(
            outputs: AttemptFile.Outputs(branch: target.branches.task, report: report.outputReport),
            claude: run.session?.attemptRecord
        )
        let pushed = try await environment.workspace(keeping: result) { () throws(WorkspaceError) in
            try await environment.git.commitAndPush(checkout, message: Self.commitMessage(task: target.task, report: report))
        }
        // 変更が無くても、前の試行が push した子ブランチがあれば、その先頭で子 PR を作る
        let head = pushed ?? checkout.head
        guard head != checkout.base else {
            throw .fail(.unexpected, "Claude は done と報告したが、作業ブランチからの変更が無い", keeping: result)
        }
        result.outputs?.commit = head
        let draft = PullRequestDraft(
            base: target.branches.epic,
            head: target.branches.task,
            title: target.task.title,
            body: Self.body(task: target.task, epic: target.epic, report: report)
        )
        let opened = try await environment.github("子 PR を作る", keeping: result) { () throws(PullRequestError) in
            try await environment.pullRequests(job.repo).openPullRequest(draft)
        }
        result.outputs?.pullRequest = opened.pullRequest.number
        return result
    }

    static func commitMessage(task: GoalFile.Task, report: TaskReport) -> String {
        "\(task.title)\n\n\(UntrustedText.head(report.summary, limit: 4_000))\n\nAskHub のタスク \(task.id)"
    }

    static func body(task: GoalFile.Task, epic: EpicFile, report: TaskReport) -> String {
        var sections = [
            "AskHub が epic「\(epic.title)」のタスク \(task.id) として実装した子 PR です。",
            "## 何をしたか\n\n\(UntrustedText.head(report.summary, limit: maximumSummaryLength))"
        ]
        if !report.decisions.isEmpty {
            let decisions = report.decisions.map { decision in
                let alternatives = decision.alternatives.isEmpty ? "" : "（ほかの案: \(decision.alternatives.joined(separator: "・"))）"
                return "- \(decision.what): \(decision.why)\(alternatives)"
            }
            sections.append("## 仮決め（人に聞かずに決めたこと）\n\n" + decisions.joined(separator: "\n"))
        }
        if !report.learnings.isEmpty {
            sections.append("## 見つけた知見\n\n" + report.learnings.map { "- \($0)" }.joined(separator: "\n"))
        }
        // GitHub の PR の本文の上限（65,536 文字）に収める
        return String(sections.joined(separator: "\n\n").prefix(60_000))
    }
}
