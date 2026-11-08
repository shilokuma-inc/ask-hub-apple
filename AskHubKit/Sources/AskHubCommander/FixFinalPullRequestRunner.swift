import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR の直し（`fixFinalPullRequest`）を 1 回実行する（`docs/renewal/flows.md` の「最終 PR までの段取り」）。
/// epic の Mac で動く（オフラインのときは、司令塔が常時オンの Mac に割り当てる）。
///
/// 直すことは、理由ごとに次から読み、作業ブランチに取り出した epic の作業場所で Claude に直させて push する。
/// - `ci`・`review`: ジョブの `dependsOn` にある最終 PR のレビューの、同じ PR と head を見て、理由に合う判定を書いた成功の試行の `outputs.findings`
/// - `human`: ジョブの元になった人の意図（署名を確かめたもの）。判断のカードの「別案にする」「直してほしい」の本文か、最終 PR への指示
/// - `conflict`: レビューの `fixConflict` の `findings` に、ワーカーが base を取り込み始めてコンフリクトしたファイルを足したもの。
///   コンフリクトしなければ Claude を使わずにマージのコミットを push し、base がもう入っていれば何もせずに今の head でレビューし直させる
///
/// 直しの回数（3 回まで）は、司令塔が試行から数える
public struct FixFinalPullRequestRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    /// コミットに書く、どのジョブの直しかの印（前の試行が push した後に落ちたかを見分ける）
    static func trailer(of job: ULID) -> String {
        "AskHub-Job: \(job.rawValue)"
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .fixFinalPullRequest) { target throws(TaskJobExit) in
            guard let input = job.input(as: FixTaskInput.self) else {
                throw .fail(.unexpected, "fixFinalPullRequest の入力（PR・head・理由）の形が違う")
            }
            let findings = try await findings(for: input, job: job)
            let pull = try await environment.tasks.github("最終 PR を読む") { () throws(PullRequestError) in
                try await environment.tasks.pullRequests(job.repo).pullRequest(number: input.pullRequest)
            }
            guard pull.state == .open, !pull.merged else { throw .fail(.unexpected, "最終 PR #\(input.pullRequest) が開いていない") }
            try FinalJobEnvironment.checkDirection(pull, branches: target.branches)
            return try await environment.exclusively(job.epic) { () throws(TaskJobExit) in
                try await fix(job, target: target, input: input, findings: findings)
            }
        }
    }

    private func fix(_ job: JobFile, target: FinalTarget, input: FixTaskInput, findings: String) async throws(TaskJobExit) -> JobResult {
        let environment = environment
        let checkout = try await environment.tasks.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutEpic(job.repo, epic: job.epic, branches: target.branches)
        }
        var result = JobResult(outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, branch: target.branches.epic))
        guard checkout.head == input.head else {
            result.outputs?.commit = try await pushedBefore(job, input: input, checkout: checkout)
            return result
        }
        var findings = findings
        var conflicts: [String] = []
        if input.reason == .conflict {
            let merged = try await environment.tasks.workspace { () throws(WorkspaceError) in
                try await environment.git.mergeBase(into: checkout)
            }
            guard let merged else {
                result.outputs?.commit = checkout.head
                return result
            }
            guard !merged.isEmpty else { return try await push(checkout, job: job, reason: input.reason, summary: "", result: result) }
            conflicts = merged
            findings = Self.conflictText(findings, files: merged)
        }
        let fixJob = FixFinalPullRequestJob(
            goal: target.goal, pullRequest: input.pullRequest, branches: target.branches, reason: input.reason, findings: findings
        )
        let (report, run) = try await environment.run(fixJob, in: checkout, target: target).done()
        result.outputs?.report = report.outputReport
        result.claude = run.session?.attemptRecord
        let left = await environment.git.unresolvedConflicts(conflicts, in: checkout)
        guard left.isEmpty else {
            throw .fail(.conflict, "コンフリクトの印が残っている（\(left.joined(separator: "・"))）", keeping: result)
        }
        return try await push(checkout, job: job, reason: input.reason, summary: report.summary, result: result)
    }

    /// 手元の変更をコミットして push し、新しい head を結果にする
    private func push(
        _ checkout: CheckedOutEpic,
        job: JobFile,
        reason: FixTaskInput.Reason,
        summary: String,
        result: JobResult
    ) async throws(TaskJobExit) -> JobResult {
        let environment = environment
        var result = result
        let message = Self.commitMessage(job: job, reason: reason, summary: summary)
        let pushed = try await environment.tasks.workspace(keeping: result) { () throws(WorkspaceError) in
            try await environment.git.commitAndPush(checkout, message: message)
        }
        // 何も変えなかった（指摘が誤っていると判断した）ときは、同じ head のまま、もう一度レビューを受ける
        result.outputs?.commit = pushed ?? checkout.head
        return result
    }

    /// 作業ブランチが直す head から進んでいるとき。前の試行が直して push した後、記録する前に落ちたのなら、その先頭を結果にする（直させ直さない）。
    /// ほかの変更で進んでいれば、古い head への直すことを今の先頭に当てずに、失敗にする
    private func pushedBefore(_ job: JobFile, input: FixTaskInput, checkout: CheckedOutEpic) async throws(TaskJobExit) -> String {
        let environment = environment
        let messages = try await environment.tasks.workspace { () throws(WorkspaceError) in
            try await environment.git.messages(after: input.head, upTo: checkout.head, in: checkout)
        }
        guard let messages else {
            throw .fail(.unexpected, "作業ブランチの先頭（\(checkout.head)）が、直す head（\(input.head)）から続いていない")
        }
        guard messages.contains(where: { $0.contains(Self.trailer(of: job.id)) }) else {
            let message = "作業ブランチが、直す head（\(input.head)）から、この直しのほかの変更で進んでいる（\(checkout.head)）。新しい head でレビューし直す"
            throw .fail(.unexpected, message)
        }
        return checkout.head
    }

    /// 直すこと（`FixTaskJob.Reason.findings` の文）
    private func findings(for input: FixTaskInput, job: JobFile) async throws(TaskJobExit) -> String {
        switch input.reason {
        case .ci, .review, .conflict:
            let verdict: ReviewVerdict = switch input.reason {
            case .ci: .fixCI
            case .conflict: .fixConflict
            default: .fixReview
            }
            let reviewed = PullRequestInput(pullRequest: input.pullRequest, head: input.head)
            let history = TaskHistory(context: environment.context, repo: job.repo, epic: job.epic)
            let found = try await history.succeeded([.reviewFinalPullRequest], task: nil).last { entry in
                job.dependsOn.contains(entry.job.id) && entry.job.input(as: PullRequestInput.self) == reviewed
                    && entry.attempt.outputs?.verdict == verdict
            }
            guard let findings = found?.attempt.outputs?.findings else {
                let message = "直すこと（最終 PR #\(input.pullRequest) の head \(input.head) を見た、dependsOn のレビューの \(verdict.rawValue) の結果）が見つからない"
                throw .fail(.unexpected, message)
            }
            return findings
        case .human:
            guard let envelope = try await environment.origin(of: job) else {
                throw .fail(.unexpected, "ジョブの元になった人の意図が無い・署名を確かめられないので、人の文で直せない")
            }
            let decisions = try await environment.tasks.read(DecisionsFile.self, at: StatePath.decisions(job.repo, job.epic))
            return FixTaskJob.Reason.human(try Self.humanText(envelope, job: job, decisions: decisions)).findings
        }
    }

    /// 人の意図から、Claude に渡す人の文を作る。最終 PR への指示と、判断のカードの「別案にする」「直してほしい」だけを受け付ける
    static func humanText(_ envelope: IntentEnvelope, job: JobFile, decisions: DecisionsFile?) throws(TaskJobExit) -> String {
        if let intent = try? InstructFinalIntent(envelope: envelope) {
            try checkTarget(repo: intent.target.repo, epic: intent.target.epic, of: job)
            return "最終 PR への指示:\n\(intent.instruction)"
        }
        guard let intent = try? DecisionIntent(envelope: envelope) else {
            throw .fail(.unexpected, "ジョブの元になった人の意図（\(envelope.kind)）は、最終 PR への指示でも判断のカードへの答えでもない")
        }
        try checkTarget(repo: intent.target.repo, epic: intent.target.epic, of: job)
        guard intent.answer != .ok else { throw .fail(.unexpected, "判断のカード \(intent.target.decision) への答えが OK なので、直すことが無い") }
        let answer = intent.answer == .alternative ? "別案にする" : "直してほしい"
        guard let item = decisions?.items.first(where: { $0.id == intent.target.decision }) else {
            return "判断のカード \(intent.target.decision) への答え: \(answer)\n人の文: \(intent.note)"
        }
        let alternatives = item.alternatives.isEmpty ? "なし" : item.alternatives.joined(separator: "・")
        return """
        判断のカード \(item.id) への答え: \(answer)
        仮決め: \(item.what)
        なぜ: \(item.why)
        ほかの案: \(alternatives)
        人の文: \(intent.note)
        """
    }

    private static func checkTarget(repo: RepositoryFullName, epic: ULID, of job: JobFile) throws(TaskJobExit) {
        guard repo == job.repo, epic == job.epic else {
            throw .fail(.unexpected, "ジョブの元になった人の意図が、ほかの epic（\(repo)・\(epic)）に向いている")
        }
    }

    /// コンフリクトの直しで Claude に渡す文。レビューの説明に、コンフリクトしたファイルを足す
    static func conflictText(_ findings: String, files: [String]) -> String {
        let list = files.map { "- \($0)" }.joined(separator: "\n")
        return FixTaskJob.Reason.conflict("\(findings)\n\nコンフリクトしたファイル:\n\(list)").findings
    }

    static func commitMessage(job: JobFile, reason: FixTaskInput.Reason, summary: String) -> String {
        let what = switch reason {
        case .ci: "CI の失敗"
        case .review: "レビューの指摘"
        case .human: "人の指示"
        case .conflict: "base とのコンフリクト"
        }
        let body = summary.isEmpty ? "" : "\(UntrustedText.head(summary, limit: 4_000))\n\n"
        return "最終 PR を直す（\(what)）\n\n\(body)AskHub の epic \(job.epic.rawValue)\n\(trailer(of: job.id))"
    }
}
