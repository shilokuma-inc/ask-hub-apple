import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 最終 PR を出す（`openFinalPullRequest`）。常時オンの Mac で動く（`docs/renewal/flows.md` の「最終 PR までの段取り」）。
///
/// 作業ブランチから base（`repo.json` の `build.baseBranch`）への PR を出す。マージは merge commit で行う。
/// 本文には、見える仮決めのカード・内部の細部の仮決め（畳む）・実機で確かめてほしいこと・人がした作業を載せる。
/// やり直しでも PR を二重に作らない（同じ作業ブランチから base への開いた PR があれば、作らずにそれを使う）
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
            body: FinalPullRequestBody.text(epic: target.epic, goal: target.goal, decisions: decisions, branches: target.branches)
        )
        let opened = try await environment.tasks.github("最終 PR を作る") { () throws(PullRequestError) in
            try await environment.tasks.pullRequests(job.repo).openPullRequest(draft)
        }
        let pull = opened.pullRequest
        try FinalJobEnvironment.checkDirection(pull, branches: target.branches)
        return JobResult(outputs: AttemptFile.Outputs(pullRequest: pull.number, commit: pull.headSHA, branch: target.branches.epic))
    }
}
