/// ワーカーが使う PR の操作。本物は `GitHubPullRequests`。ワーカーのテストでは偽物に差し替える
public protocol PullRequestOperations: Sendable {
    /// PR を作る。同じ head・base の開いた PR がすでにあれば、作らずにそれを返す
    func openPullRequest(_ draft: PullRequestDraft) async throws(PullRequestError) -> OpenedPullRequest
    /// PR の様子を読む
    func pullRequest(number: Int) async throws(PullRequestError) -> PullRequest
    /// head の SHA の CI を読み、まとめた状態を返す
    func checks(at sha: String, policy: CheckPolicy) async throws(PullRequestError) -> CheckSummary
    /// head の SHA の check run（名前ごとの最新）と、結果の見出し
    func checkRuns(at sha: String) async throws(PullRequestError) -> [CheckRunStatus]
    /// head の SHA の commit status（context ごとの最新）と、その説明
    func commitStatuses(at sha: String) async throws(PullRequestError) -> [CommitStatus]
    /// GitHub Actions の run の、落ちた job だけを流し直す
    func rerunFailedJobs(runID: Int) async throws(PullRequestError)
    /// GitHub Actions の job のログ（長いログは末尾だけ）
    func jobLog(jobID: Int) async throws(PullRequestError) -> String
    /// 信用する書き手の、未解決の行コメントのスレッドとレビューの本文を読む
    func reviewFeedback(number: Int, trusted: TrustedAuthors) async throws(PullRequestError) -> ReviewFeedback
    /// merge commit でマージする。`headSHA` と今の head が違えば断る
    func merge(
        number: Int,
        headSHA: String,
        commitTitle: String?,
        commitMessage: String?
    ) async throws(PullRequestError) -> MergedPullRequest
    /// ブランチを消す。今の先頭が `expectedSHA` と違えば消さない
    func deleteBranch(_ branch: String, expectedSHA: String) async throws(PullRequestError) -> BranchDeletion
}

extension GitHubPullRequests: PullRequestOperations {}
