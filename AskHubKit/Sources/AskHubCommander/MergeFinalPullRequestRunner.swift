import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR のマージ（`mergeFinalPullRequest`）を 1 回実行する（`docs/renewal/flows.md` の「マージの規則」）。常時オンの Mac で動く。
///
/// - input の head を固定して merge commit でマージする。今の head が違えば、マージせずに失敗にする（承認や判定の後に push された変更をマージしない）
/// - マージの規則で人の確認が要る最終 PR（見える仮決めがある・レビューがマージの規則の材料を返した）は、同じ head への人の承認（`approveMerge`）を
///   元にしたジョブでだけマージする。司令塔の取り違えで、人の確認を飛ばさないよう、ワーカーでも確かめる
/// - マージしたら作業ブランチを消す（マージの後に push されていれば残す）。子 PR のマージの後に push されて残った子ブランチも消す
public struct MergeFinalPullRequestRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .mergeFinalPullRequest) { target throws(TaskJobExit) in
            try await merge(job, target)
        }
    }

    private func merge(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: PullRequestInput.self) else {
            throw .fail(.unexpected, "mergeFinalPullRequest の入力（PR と head）の形が違う")
        }
        let environment = environment
        let pulls = environment.tasks.pullRequests(job.repo)
        let pull = try await environment.tasks.github("最終 PR を読む") { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        try FinalJobEnvironment.checkDirection(pull, branches: target.branches)
        // 前の試行がマージした後、記録する前に落ちた（見る head でマージしたものだけを、終わったとみなす）
        if pull.merged {
            guard pull.headSHA == input.head else {
                throw .fail(.unexpected, "最終 PR #\(input.pullRequest) は、マージする head（\(input.head)）ではなく \(pull.headSHA) でマージされている")
            }
            return try await merged(job, input, sha: pull.mergeCommitSHA, target: target, pulls: pulls)
        }
        guard pull.state == .open else { throw .fail(.unexpected, "最終 PR #\(input.pullRequest) が開いていない") }
        guard pull.headSHA == input.head else {
            throw .fail(.unexpected, "最終 PR #\(input.pullRequest) の head が、マージする head（\(input.head)）から動いた（\(pull.headSHA)）")
        }
        try await checkApproval(job, input: input)
        let merge = try await environment.tasks.github("最終 PR をマージする") { () throws(PullRequestError) in
            try await pulls.merge(number: input.pullRequest, headSHA: input.head, commitTitle: nil, commitMessage: nil)
        }
        // マージの API は向き先を固定できないので、base 以外に入っていないかを確かめる。取り消せないので、人へ渡す
        let landed = try await environment.tasks.github("マージした最終 PR を読む") { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        guard landed.baseRef == target.branches.base else {
            throw .fail(.unexpected, "最終 PR #\(input.pullRequest) が、base（\(target.branches.base)）ではなく \(landed.baseRef) にマージされた。人が確かめる")
        }
        return try await merged(job, input, sha: merge.sha ?? landed.mergeCommitSHA, target: target, pulls: pulls)
    }

    /// マージの規則で人の確認が要るなら、ジョブの元が同じ head への人の承認かを確かめる
    private func checkApproval(_ job: JobFile, input: PullRequestInput) async throws(TaskJobExit) {
        let history = TaskHistory(context: environment.context, repo: job.repo, epic: job.epic)
        let review = try await history.succeeded([.reviewFinalPullRequest], task: nil).last { entry in
            entry.job.input(as: PullRequestInput.self) == input && entry.attempt.outputs?.verdict == .ready
        }
        guard let review else {
            throw .fail(.unexpected, "最終 PR #\(input.pullRequest) の head \(input.head) を ready と判定したレビューが無い")
        }
        let decisions = try await environment.tasks.read(DecisionsFile.self, at: StatePath.decisions(job.repo, job.epic))
        // マージの規則の材料が無い（読めない）ときは、人の確認が要るものとして扱う
        let risks = review.attempt.outputs?.mergeRisks
        let reasons = FinalMergeRule.manualReasons(decisions: decisions, mergeRisks: risks ?? [])
        guard risks == nil || !reasons.isEmpty else { return }
        guard FinalMergeRule.canApprove(decisions: decisions) else {
            throw .fail(.unexpected, "見える仮決めに、人がまだ答えていないものがあるので、マージしない")
        }
        let approval = try await environment.origin(of: job).flatMap { try? ApproveMergeIntent(envelope: $0) }
        guard let approval, approval.target.repo == job.repo, approval.target.epic == job.epic, approval.target.head == input.head else {
            let message = "人の確認が要る最終 PR（\(Self.describe(reasons))）なのに、head \(input.head) への人の承認（approveMerge）を元にしたジョブでないので、マージしない"
            throw .fail(.unexpected, message)
        }
    }

    static func describe(_ reasons: [FinalMergeRule.ManualReason]) -> String {
        guard !reasons.isEmpty else { return "マージの規則の材料が読めない" }
        let texts = reasons.map { reason in
            switch reason {
            case let .visibleDecisions(count): "見える仮決めが \(count) 件"
            case let .risk(risk): "\(risk.kind.rawValue): \(risk.reason)"
            }
        }
        return texts.joined(separator: "・")
    }

    /// マージした作業ブランチと、残った子ブランチを消して終える。消す前に作業ブランチへ push されていたら、消さずに残す
    private func merged(
        _ job: JobFile,
        _ input: PullRequestInput,
        sha: String?,
        target: FinalTarget,
        pulls: any PullRequestOperations
    ) async throws(TaskJobExit) -> JobResult {
        do {
            _ = try await pulls.deleteBranch(target.branches.epic, expectedSHA: input.head)
        } catch .headChanged {
            // マージは済んでいる。マージの後に push されたものは失わないよう残す
        } catch {
            throw .finish(JobResult(failure: error.attemptFailure(doing: "マージした作業ブランチを消す", now: environment.context.now())))
        }
        try await removeChildBranches(job, target: target, pulls: pulls)
        guard let sha, AttemptFile.isCommitSHA(sha) else {
            throw .fail(.unexpected, "最終 PR #\(input.pullRequest) のマージコミットが分からない")
        }
        return JobResult(outputs: AttemptFile.Outputs(pullRequest: input.pullRequest, commit: sha, branch: target.branches.epic))
    }

    /// 子 PR のマージの後に push されて残った子ブランチ（`<作業ブランチ>-<タスク>`。`ReviewTaskRunner` は消さずに残す）を消す。
    ///
    /// この epic のタスク（ゴールのタスクと、ジョブのタスク）の子ブランチだけを見るので、ほかの epic のものには触れない。
    /// 開いた PR のあるブランチ（消すと PR が閉じる）と、読んでから消すまでの間に push されたブランチは残す
    private func removeChildBranches(_ job: JobFile, target: FinalTarget, pulls: any PullRequestOperations) async throws(TaskJobExit) {
        let environment = environment
        let jobs: [JobFile]
        do {
            jobs = try await environment.context.jobList(job.repo, epic: job.epic).jobs
        } catch {
            throw .state(error)
        }
        let tasks = Set(target.goal.tasks.map(\.id) + jobs.compactMap(\.task))
        for task in tasks.sorted() {
            let branch = TaskBranches.child(of: target.branches.epic, task: task)
            guard EpicFile.isBranchName(branch) else { continue }
            let head = try await environment.tasks.github("残った子ブランチを読む") { () throws(PullRequestError) in
                try await pulls.branchHead(branch)
            }
            guard let head else { continue }
            let opened = try await environment.tasks.github("残った子ブランチの PR を読む") { () throws(PullRequestError) in
                try await pulls.openPullRequests(head: branch)
            }
            guard opened.isEmpty else { continue }
            do {
                _ = try await pulls.deleteBranch(branch, expectedSHA: head)
            } catch .headChanged {
                // 読んだ後に push された。push されたものは失わないよう残す
            } catch {
                throw .finish(JobResult(failure: error.attemptFailure(doing: "残った子ブランチを消す", now: environment.context.now())))
            }
        }
    }
}
