import Foundation

extension GitHubPullRequests {
    /// head の SHA の GitHub Actions の実行（workflow run）を、ページングを最後まで追って読む。
    ///
    /// 待つチェックが出ないときに、実行が無いのか、実行が queued のまま止まっているのかを見分けるのに使う
    public func workflowRuns(at sha: String) async throws(PullRequestError) -> [WorkflowRun] {
        try GitNames.checkSHA(sha)
        let query = [URLQueryItem(name: "head_sha", value: sha), URLQueryItem(name: "per_page", value: "100")]
        let pages = try await api.pages("actions/runs", query: query, as: WorkflowRunsPage.self)
        return pages.flatMap(\.workflowRuns).map(\.model)
    }

    /// GitHub Actions の実行の、最後の試行のジョブの数。数（`total_count`）だけを読むので、1 件ずつのページの最初だけを読む
    public func jobCount(runID: Int) async throws(PullRequestError) -> Int {
        try GitNames.checkNumber(runID)
        let query = [URLQueryItem(name: "per_page", value: "1")]
        return try await api.get("actions/runs/\(runID)/jobs", query: query, as: JobsPage.self).totalCount
    }

    /// PR を閉じる・開き直す
    public func setState(number: Int, to state: PullRequest.State) async throws(PullRequestError) {
        try GitNames.checkNumber(number)
        _ = try await api.send("PATCH", api.url("pulls/\(number)"), body: StateBody(state: state.rawValue))
    }
}

/// GitHub Actions の実行（workflow run）の今の様子
public struct WorkflowRun: Sendable, Equatable {
    /// 実行の id。新しく作られた実行ほど大きい
    public var id: Int
    /// ワークフローの名前
    public var name: String
    /// 起こしたイベント（`push`・`pull_request` など）
    public var event: String
    /// `queued`・`in_progress`・`completed`（`waiting`・`requested`・`pending` も使う）
    public var status: String
    /// 最後の試行が始まった時刻（`run_started_at`。無ければ作られた時刻）。読めなければ nil
    public var startedAt: Date?

    public init(id: Int, name: String, event: String, status: String, startedAt: Date?) {
        self.id = id
        self.name = name
        self.event = event
        self.status = status
        self.startedAt = startedAt
    }
}

// MARK: - 要求と応答の形（キーは `convertFromSnakeCase` で読む）

private struct StateBody: Encodable, Sendable {
    let state: String
}

struct WorkflowRunsPage: Decodable {
    let workflowRuns: [WorkflowRunPayload]
}

struct WorkflowRunPayload: Decodable {
    let id: Int
    /// ワークフローのファイルに `name` が無ければ null になる
    let name: String?
    let event: String
    let status: String?
    /// 時刻は、読めない値で一覧ごと読めなくならないよう、文字列で受けて読めるものだけ使う
    let createdAt: String?
    let runStartedAt: String?

    var model: WorkflowRun {
        WorkflowRun(
            id: id,
            name: name ?? "",
            event: event,
            status: status ?? "unknown",
            startedAt: (runStartedAt ?? createdAt).flatMap(GitHubDate.parse)
        )
    }
}

struct JobsPage: Decodable {
    let totalCount: Int
}
