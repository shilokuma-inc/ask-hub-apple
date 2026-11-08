import AskHubProtocol
import AskHubPullRequests
import Foundation

/// タスクの直し（`fixTask`）を 1 回実行する（`docs/renewal/flows.md` の「タスクの流れ」）。epic の Mac で動く。
///
/// 子 PR のレビュー（`reviewTask`）が書いた直すこと（`outputs.findings`）を付けて、実装の会話を再開して直させ、子ブランチに push する。
/// 直しの回数（3 回まで）は、司令塔が試行から数える。
///
/// 人に聞きたいこと（`needsQuestion`）があれば、手元の変更を残したまま質問で成功として終える。答えで再開するジョブ（入力の `question`）は、
/// 質問した作業場所が残っていればそのまま使って質問した会話を再開し、会話を再開できなければ新しい会話で（ゴールとタスクも渡して）続けさせる。
/// 作業場所が無ければ取り出し直して、新しい会話で直させ直す（`QuestionResumption.answer`）
public struct FixTaskRunner: JobRunning {
    public var environment: TaskJobEnvironment

    public init(environment: TaskJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .fixTask) { target throws(TaskJobExit) in
            try await environment.exclusively(job.epic) { () throws(TaskJobExit) in try await fix(job, target) }
        }
    }

    private func fix(_ job: JobFile, _ target: TaskTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: FixTaskInput.self) else { throw .fail(.unexpected, "fixTask の入力（PR・head・理由）の形が違う") }
        let environment = environment
        let history = TaskHistory(context: environment.context, repo: job.repo, epic: job.epic)
        guard let findings = try await history.findings(for: input, task: target.task.id) else {
            throw .fail(.unexpected, "直すこと（子 PR #\(input.pullRequest) の head \(input.head) を見たレビューの結果）が見つからない")
        }
        // 実装の途中の質問の答えで再開するときは、質問した会話（無ければ新しい会話）を使うので、実装の会話は要らない
        let resumption = try await environment.resumption(of: job, question: input.question, task: target.task.id)
        var conversation: TaskHistory.Conversation?
        if resumption == nil { conversation = try await implementationConversation(of: target.task.id, history: history) }
        try await checkPullRequest(input.pullRequest, of: job, target: target)
        // 答えで再開するときは、質問したときの作業場所が残っていれば、取り出し直さずに（手元の変更を残して）使う
        let kept = try await environment.keptTask(resumption, job: job, branches: target.branches)
        var checkout: CheckedOutTask
        if let kept {
            checkout = kept
        } else {
            checkout = try await environment.workspace { () throws(WorkspaceError) in
                try await environment.git.checkOutTask(job.repo, epic: job.epic, branches: target.branches)
            }
        }
        var result = JobResult(outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, branch: target.branches.task))
        guard checkout.head == input.head else {
            result.outputs?.commit = try await pushedBefore(job, input: input, checkout: checkout)
            return result
        }
        let reply: TaskReply
        if let resumption {
            // 新しい会話で直させるときは、実装の会話に無いゴールとタスクを渡す
            let background = ImplementTaskJob.background(goal: target.goal, task: target.task)
            let fix = FixTaskJob(
                session: nil, pullRequest: input.pullRequest, reason: input.reason, findings: findings, background: background
            )
            reply = await resumption.answer(fix, kept: kept != nil) { await environment.run($0, in: checkout, target: target) }
        } else {
            let fix = FixTaskJob(session: conversation?.session, pullRequest: input.pullRequest, reason: input.reason, findings: findings)
            reply = await environment.run(fix, in: checkout, target: target)
        }
        // 人に聞きたいことがあれば、手元の変更を残したまま、commit・push をせずに質問で終える
        let (report, run) = try reply.done(keeping: result)
        result.outputs?.report = report.outputReport
        result.claude = run.session?.attemptRecord
        let message = Self.commitMessage(task: target.task, reason: input.reason, report: report, job: job.id)
        let pushed = try await environment.workspace(keeping: result) { () throws(WorkspaceError) in
            try await environment.git.commitAndPush(checkout, message: message)
        }
        // 何も変えなかった（指摘が誤っていると判断した）ときは、同じ head のまま、もう一度レビューを受ける
        result.outputs?.commit = pushed ?? checkout.head
        return result
    }

    /// 子ブランチが直す head から進んでいる。前の試行が直して push した後、記録する前に落ちたのなら、その先頭を結果にする（直させ直さない）。
    /// 答えで再開した直しは、この直しが push したコミット（`trailer`）で進んだときだけ結果にする。質問の後にほかの変更で進んでいたら、
    /// 人の答えを渡さないまま成功にしない（ふつうの直しは、進んだ head をレビューし直すので、そのまま結果にする）
    private func pushedBefore(_ job: JobFile, input: FixTaskInput, checkout: CheckedOutTask) async throws(TaskJobExit) -> String {
        let environment = environment
        let advanced = try await environment.workspace { () throws(WorkspaceError) in
            try await environment.git.isAncestor(input.head, of: checkout.head, in: checkout)
        }
        guard advanced else {
            throw .fail(.unexpected, "子ブランチの先頭（\(checkout.head)）が、直す head（\(input.head)）から続いていない")
        }
        guard input.question != nil else { return checkout.head }
        let messages = try await environment.workspace { () throws(WorkspaceError) in
            try await environment.git.messages(after: input.head, upTo: checkout.head, in: checkout)
        }
        guard messages?.contains(where: { $0.contains(FixFinalPullRequestRunner.trailer(of: job.id)) }) == true else {
            let message = "子ブランチが、質問の後にほかの変更で進んだ（\(checkout.head)）。人の答え（\(input.question ?? "")）を渡せないので、人に確かめてもらう"
            throw .fail(.unexpected, message)
        }
        return checkout.head
    }

    /// 子 PR が開いていて、子ブランチから作業ブランチに向いているか
    private func checkPullRequest(_ number: Int, of job: JobFile, target: TaskTarget) async throws(TaskJobExit) {
        let environment = environment
        let pull = try await environment.github("子 PR を読む") { () throws(PullRequestError) in
            try await environment.pullRequests(job.repo).pullRequest(number: number)
        }
        guard pull.state == .open, !pull.merged else { throw .fail(.unexpected, "子 PR #\(number) が開いていない") }
        try ReviewTaskRunner.checkDirection(pull, branches: target.branches)
    }

    /// 実装の会話（会話はそれを動かした Mac にだけ残るので、ほかの Mac では再開できない。epic を Mac の間で引き継ぐときに、新しい会話で直す形を足す）
    private func implementationConversation(of task: String, history: TaskHistory) async throws(TaskJobExit) -> TaskHistory.Conversation {
        guard let conversation = try await history.conversation(of: task) else {
            throw .fail(.unexpected, "タスク \(task) の実装の会話（implementTask の試行の claude.session）が見つからない")
        }
        guard conversation.mac == environment.context.mac else {
            throw .fail(.unexpected, "実装の会話は \(conversation.mac) にあり、この Mac（\(environment.context.mac)）では再開できない")
        }
        return conversation
    }

    /// 最後の行に、どのジョブの直しかの印を書く（答えで再開した直しで、前の試行が push した後に落ちたかを見分ける）
    static func commitMessage(task: GoalFile.Task, reason: FixTaskInput.Reason, report: TaskReport, job: ULID) -> String {
        let what = reason == .ci ? "CI の失敗" : "レビューの指摘"
        let summary = UntrustedText.head(report.summary, limit: 4_000)
        return "\(task.title)（\(what)を直す）\n\n\(summary)\n\nAskHub のタスク \(task.id)\n\(FixFinalPullRequestRunner.trailer(of: job))"
    }
}
