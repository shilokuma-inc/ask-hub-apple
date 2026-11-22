import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR を出す（`openFinalPullRequest`）。常時オンの Mac で動く（`docs/renewal/flows.md` の「最終 PR までの段取り」）。
///
/// 作業ブランチから base（`repo.json` の `build.baseBranch`）への PR を出す。マージは merge commit で行う。
/// 本文には、見える仮決めのカード・内部の細部の仮決め（畳む）・実機で確かめてほしいこと・人がした作業を載せる。
/// やり直しでも PR を二重に作らない（同じ作業ブランチから base への開いた PR があれば、作らずにそれを使う）。
///
/// 人が飛ばしたタスクの子 PR（子ブランチから作業ブランチへの開いた PR）は、最終 PR を出した後に、マージせずに閉じてコメントを書く。
/// 作業ブランチを消しても GitHub は開いた子 PR を閉じず、向き先を base に変えるので、閉じられなければ試行の失敗にする（やり直しで続きをする）。
/// コメントは理由を添えるだけなので、書けなくても止めない（理由は最終 PR の本文にも書く）
public struct OpenFinalPullRequestRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .openFinalPullRequest) { target throws(TaskJobExit) in
            try await open(job, target)
        }
    }

    private func open(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        let environment = environment
        let decisions = try await environment.tasks.read(DecisionsFile.self, at: StatePath.decisions(job.repo, job.epic))
        let title = target.epic.title.isBlank ? "AskHub の epic \(target.epic.id.rawValue)" : target.epic.title
        let draft = PullRequestDraft(
            base: target.branches.base,
            head: target.branches.epic,
            title: title,
            body: FinalPullRequestBody.text(
                epic: target.epic,
                goal: target.goal,
                decisions: decisions,
                branches: target.branches,
                capturesScreenshots: target.settings.screenshots != nil
            )
        )
        let opened = try await environment.tasks.github("最終 PR を作る") { () throws(PullRequestError) in
            try await environment.tasks.pullRequests(job.repo).openPullRequest(draft)
        }
        let pull = opened.pullRequest
        try FinalJobEnvironment.checkDirection(pull, branches: target.branches)
        let outputs = AttemptFile.Outputs(pullRequest: pull.number, commit: pull.headSHA, branch: target.branches.epic)
        try await closeSkippedPullRequests(job, target, keeping: JobResult(outputs: outputs))
        return JobResult(outputs: outputs)
    }

    /// 飛ばしたタスクの子ブランチから作業ブランチへの開いた PR を、すべて閉じてからコメントを書く（先にコメントを書くと、閉じられずにやり直したときに重なる）。
    /// 飛ばしたときに記録した子 PR のほか、飛ばした後に元の試行が作った PR も閉じる。一覧を読めない・閉じられないときは試行の失敗として終える
    private func closeSkippedPullRequests(_ job: JobFile, _ target: FinalTarget, keeping partial: JobResult) async throws(TaskJobExit) {
        let environment = environment
        let pulls = environment.tasks.pullRequests(job.repo)
        for task in target.goal.tasks where task.state == .skipped {
            let head = TaskBranches.child(of: target.branches.epic, task: task.id)
            let open = try await environment.tasks.github("飛ばしたタスクの子 PR を探す", keeping: partial) { () throws(PullRequestError) in
                try await pulls.openPullRequests(head: head, base: target.branches.epic)
            }
            for pull in open {
                try await environment.tasks.github("飛ばしたタスクの子 PR を閉じる", keeping: partial) { () throws(PullRequestError) in
                    try await pulls.setState(number: pull.number, to: .closed)
                }
                try? await pulls.comment(number: pull.number, body: Self.skippedComment(task: task, epic: target.epic))
            }
        }
    }

    /// 閉じた子 PR に書くコメント。最後の行に目印（`{"type":"skippedTask","epic":"…","task":"…"}`）を置く（書くだけで読まない）
    static func skippedComment(task: GoalFile.Task, epic: EpicFile) -> String {
        let reason = task.skip.map { "（\(FinalPullRequestBody.safe($0.text))）" } ?? ""
        let body = "AskHub で、この子 PR のタスク \(task.id) を人が飛ばした\(reason)ので、マージせずに閉じました。ブランチは消さずに残しています。"
        let marker = JSONValue.object(["type": .string("skippedTask"), "epic": .string(epic.id.rawValue), "task": .string(task.id)])
        return ProtocolMarker.text(body: body, marker: marker)
    }
}
