import AskHubProtocol
import Foundation

/// ワークフローを起動して、その実行を見張る（App Store のスクショの撮影。`docs/renewal/store-screenshots.md` の「撮影の起動と見張り」）。
/// 使うのは Actions の読み書きの権限だけで、ワークフローのファイルは書かない
extension GitHubPullRequests {
    /// `workflow_dispatch` のワークフローを `ref` で起動する。`return_run_details` で、起動した実行の id と画面の URL を返す
    /// （2026-02-19 から 200 で返る。古い形の 204 なら nil を返すので、呼ぶ側が一覧から探す）。入力の値は文字列で送る
    public func dispatchWorkflow(
        _ workflow: String,
        ref: String,
        inputs: [String: String]
    ) async throws(PullRequestError) -> DispatchedRun? {
        try Self.checkWorkflow(workflow)
        try GitNames.checkBranch(ref)
        guard inputs.count <= 25 else { throw .invalidArgument("ワークフローの入力が 25 を超える") }
        let body = DispatchBody(ref: ref, inputs: inputs, returnRunDetails: true)
        let (data, response) = try await api.send("POST", api.url("actions/workflows/\(workflow)/dispatches"), body: body)
        guard response.statusCode == 200, !data.isEmpty else { return nil }
        let reply = try GitHubAPI.decode(DispatchReply.self, from: data, what: "ワークフローの起動")
        guard reply.workflowRunId > 0 else { throw .malformed("起動した実行の id が無い") }
        return DispatchedRun(id: reply.workflowRunId, url: reply.htmlUrl.flatMap(Self.runPage))
    }

    /// 1 つの実行の今の様子
    public func workflowRun(id: Int) async throws(PullRequestError) -> WorkflowRunDetail {
        try GitNames.checkNumber(id)
        let run = try await api.get("actions/runs/\(id)", as: WorkflowRunDetailPayload.self)
        guard let model = run.model else { throw .malformed("実行 \(id) の形が違う") }
        return model
    }

    /// ワークフローの、ブランチで `workflow_dispatch` から起こした実行（新しい順。ページングを最後まで追う）。
    /// 起動した直後に落ちて id を書けなかったときに探すのに使う（release ブランチの撮影の実行はふつう数件なので、1 ページで済む）
    public func dispatchedRuns(_ workflow: String, branch: String) async throws(PullRequestError) -> [WorkflowRunDetail] {
        try Self.checkWorkflow(workflow)
        try GitNames.checkBranch(branch)
        let query = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "event", value: "workflow_dispatch"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        let pages = try await api.pages("actions/workflows/\(workflow)/runs", query: query, as: WorkflowRunDetailsPage.self)
        return pages.flatMap(\.workflowRuns).compactMap(\.model)
    }

    /// 実行を取り消す（終わっている実行なら GitHub が 409 で断る）
    public func cancelWorkflowRun(id: Int) async throws(PullRequestError) {
        try GitNames.checkNumber(id)
        _ = try await api.send("POST", api.url("actions/runs/\(id)/cancel"))
    }

    static func checkWorkflow(_ workflow: String) throws(PullRequestError) {
        guard StoreScreenshotWorkflow.isWorkflowFile(workflow) else { throw .invalidArgument("ワークフローのファイル名の形が違う") }
    }

    /// 実行の画面の URL（GitHub の https のものだけ）
    static func runPage(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }
}

/// 起動した実行
public struct DispatchedRun: Sendable, Equatable {
    public var id: Int
    /// 実行の画面（`html_url`）
    public var url: URL?

    public init(id: Int, url: URL?) {
        self.id = id
        self.url = url
    }
}

/// GitHub Actions の 1 つの実行の様子（撮影の見張り）
public struct WorkflowRunDetail: Sendable, Equatable {
    public var id: Int
    /// `queued`・`in_progress`・`completed`（`waiting`・`requested`・`pending` も使う）
    public var status: String
    /// 終わった実行の結論（`success`・`failure`・`cancelled`・`timed_out` など）。終わっていなければ nil
    public var conclusion: String?
    public var event: String
    /// ワークフローのファイルのパス（`.github/workflows/app-store-screenshots.yml`）
    public var path: String
    public var headBranch: String?
    public var headSHA: String
    /// 作られた時刻
    public var createdAt: Date
    /// 実行の画面
    public var url: URL?

    public init(
        id: Int,
        status: String,
        conclusion: String?,
        event: String,
        path: String,
        headBranch: String?,
        headSHA: String,
        createdAt: Date,
        url: URL?
    ) {
        self.id = id
        self.status = status
        self.conclusion = conclusion
        self.event = event
        self.path = path
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.createdAt = createdAt
        self.url = url
    }

    public var isCompleted: Bool { status == "completed" }
}

// MARK: - 要求と応答の形（応答のキーは `convertFromSnakeCase` で読む）

private struct DispatchBody: Encodable, Sendable {
    let ref: String
    let inputs: [String: String]
    let returnRunDetails: Bool

    enum CodingKeys: String, CodingKey {
        case ref, inputs
        case returnRunDetails = "return_run_details"
    }
}

private struct DispatchReply: Decodable {
    let workflowRunId: Int
    let htmlUrl: String?
}

private struct WorkflowRunDetailsPage: Decodable {
    let workflowRuns: [WorkflowRunDetailPayload]
}

private struct WorkflowRunDetailPayload: Decodable {
    let id: Int
    let status: String?
    let conclusion: String?
    let event: String?
    let path: String?
    let headBranch: String?
    let headSha: String?
    let createdAt: String?
    let htmlUrl: String?

    /// 読めない実行（欄が欠けている）は nil
    var model: WorkflowRunDetail? {
        guard id > 0, let status, let event, let path, let headSha, let created = createdAt.flatMap(GitHubDate.parse) else { return nil }
        return WorkflowRunDetail(
            id: id,
            status: status,
            conclusion: conclusion,
            event: event,
            path: path,
            headBranch: headBranch,
            headSHA: headSha,
            createdAt: created,
            url: htmlUrl.flatMap(GitHubPullRequests.runPage)
        )
    }
}
