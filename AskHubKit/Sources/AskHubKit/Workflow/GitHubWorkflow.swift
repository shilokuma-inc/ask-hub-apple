import Foundation

/// 1 つのワークフローの有無・run の取得・起動。テストやデモモードでは差し替える
public protocol WorkflowProviding: Sendable {
    /// ワークフローのファイル名（例: `release-prepare.yml`）
    var file: String { get }
    /// ワークフローがリポジトリにあるか
    func availability(repository: String) async throws -> WorkflowAvailability
    /// `branch` で実行した直近の run
    func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun
    /// 新しい順の run を `limit` 件まで（ページングはしない）。`branch`・`event` が `nil` なら絞らない
    func recentRuns(repository: String, branch: String?, event: String?, limit: Int) async throws -> [WorkflowRun]
    /// `ref` で起動する（`workflow_dispatch`）。`inputs` が空なら送らない
    func dispatch(repository: String, ref: String, inputs: [String: String]) async throws
}

/// GitHub の REST API で、1 つのワークフロー（`.github/workflows/<file>`）の run を読み、`workflow_dispatch` で起動する。
/// `upload.yml`（`GitHubUploadWorkflow`）とリリースのワークフロー（`ReleaseWorkflow`）で共通に使う
public struct GitHubWorkflow: WorkflowProviding {
    /// ワークフローのファイル名（例: `upload.yml`）。API の `workflow_id` にはファイル名をそのまま使える
    public let file: String

    private let client: GitHubClient

    public init(client: GitHubClient, file: String) {
        self.client = client
        self.file = file
    }

    /// ワークフローがリポジトリにあるか。ファイルがあるかは既定ブランチ（と run のあるブランチ）で判定される。
    /// アプリはこれが `.notFound` のリポジトリでは、そのワークフローを使う操作を出さない（`upload.yml` の 404 の扱いと同じ）
    ///
    /// - Throws: レート制限でない 403 は `WorkflowError.permissionDenied`。それ以外は `GitHubError` のまま
    public func availability(repository: String) async throws -> WorkflowAvailability {
        let workflow: WorkflowNode
        do {
            workflow = try await client.get("repos/\(repository)/actions/workflows/\(file)", as: WorkflowNode.self)
        } catch GitHubError.http(status: 404, _) {
            return .notFound
        } catch GitHubError.http(status: 403, _) {
            throw WorkflowError.permissionDenied
        }
        return workflow.state == "active" ? .active : .disabled(state: workflow.state)
    }

    /// `repository`（`owner/repo`）の `branch` で実行した直近の run。404 は `.unsupported` で返す
    public func latestRun(repository: String, branch: String) async throws -> LatestWorkflowRun {
        // 直近の 1 件だけが要るので、ページングはせず per_page を 1 にする（run は新しい順に返る）。
        // branch で絞ると push と workflow_dispatch の両方の run が返る。どちらも対象にする
        let page: RunsPage
        do {
            page = try await client.get(
                "repos/\(repository)/actions/workflows/\(file)/runs",
                query: [
                    URLQueryItem(name: "branch", value: branch),
                    URLQueryItem(name: "per_page", value: "1")
                ],
                as: RunsPage.self
            )
        } catch GitHubError.http(status: 404, _) {
            return .unsupported
        } catch GitHubError.http(status: 403, _) {
            // レート制限の 403 は GitHubClient が待って再試行するか rateLimited を投げるので、ここに来る 403 は権限不足
            throw WorkflowError.permissionDenied
        }
        guard let run = page.workflowRuns.first else {
            return .noRuns
        }
        return .run(Self.makeRun(run, repository: repository, branch: branch))
    }

    /// 新しい順の run を `limit` 件まで（1〜100 に丸める）。直近の数件だけが要るので、ページングはしない。
    /// 起動の直後の run を探すとき（dispatch は run の id を返さない）は、`event: "workflow_dispatch"` で絞り、開始時刻で見分ける
    ///
    /// - Parameters:
    ///   - branch: 実行したブランチで絞る（`nil` なら絞らない）
    ///   - event: 起動のきっかけ（`workflow_dispatch`・`schedule` など）で絞る（`nil` なら絞らない）
    /// - Throws: 404 は `WorkflowError.workflowNotFound`、レート制限でない 403 は `.permissionDenied`
    public func recentRuns(repository: String, branch: String? = nil, event: String? = nil, limit: Int = 10) async throws -> [WorkflowRun] {
        var query = [URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 100)))]
        if let branch {
            query.append(URLQueryItem(name: "branch", value: branch))
        }
        if let event {
            query.append(URLQueryItem(name: "event", value: event))
        }
        let page: RunsPage
        do {
            page = try await client.get("repos/\(repository)/actions/workflows/\(file)/runs", query: query, as: RunsPage.self)
        } catch GitHubError.http(status: 404, _) {
            throw WorkflowError.workflowNotFound
        } catch GitHubError.http(status: 403, _) {
            throw WorkflowError.permissionDenied
        }
        return page.workflowRuns.map { Self.makeRun($0, repository: repository, branch: branch ?? "") }
    }

    /// `repository` のワークフローを `ref`（ブランチ名）で起動する（`workflow_dispatch`）。
    /// `inputs` はワークフローの `on.workflow_dispatch.inputs` に渡す値（GitHub の API では文字列で渡す。boolean の入力は `"true"` / `"false"`）。空なら送らない。
    /// 起動の直後は run の一覧に新しい run がすぐには出ないので、呼び出し側は「起動した」状態を保つ
    ///
    /// - Throws: `WorkflowError.workflowNotFound`（404）・`.dispatchNotSupported(message:)`（422）・`.permissionDenied`（レート制限でない 403）。
    ///   それ以外は `GitHubError` のまま
    public func dispatch(repository: String, ref: String, inputs: [String: String] = [:]) async throws {
        // 成功は 204。新しい API では 200 で run の情報を返すことがあるが、どちらも 2xx なので本文は読まない
        do {
            try await client.send(
                "POST",
                "repos/\(repository)/actions/workflows/\(file)/dispatches",
                body: DispatchRequest(ref: ref, inputs: inputs.isEmpty ? nil : inputs)
            )
        } catch GitHubError.http(status: 404, _) {
            throw WorkflowError.workflowNotFound
        } catch GitHubError.http(status: 422, let message) {
            throw WorkflowError.dispatchNotSupported(message: message)
        } catch GitHubError.http(status: 403, _) {
            throw WorkflowError.permissionDenied
        }
    }

    private static func makeRun(_ run: RunNode, repository: String, branch: String) -> WorkflowRun {
        WorkflowRun(
            id: run.id,
            repository: repository,
            branch: run.headBranch ?? branch,
            headSHA: run.headSha,
            // status は API の定義上 null になりうる。知らない値と同じく other で保持する
            status: .init(rawValue: run.status ?? ""),
            conclusion: run.conclusion.map(WorkflowRun.Conclusion.init(rawValue:)),
            event: run.event,
            startedAt: run.runStartedAt ?? run.createdAt,
            url: run.htmlUrl,
            displayTitle: run.displayTitle
        )
    }
}

// MARK: - リクエストとレスポンスの形

private struct DispatchRequest: Encodable, Sendable {
    let ref: String
    /// `nil` なら JSON に含めない（inputs の無いワークフローに空のオブジェクトを送らない）
    let inputs: [String: String]?
}

private struct RunsPage: Decodable {
    let workflowRuns: [RunNode]

    private enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct RunNode: Decodable {
    let id: Int
    let headBranch: String?
    let headSha: String
    let status: String?
    let conclusion: String?
    let event: String
    let runStartedAt: Date?
    let createdAt: Date
    let htmlUrl: URL
    let displayTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case status
        case conclusion
        case event
        case runStartedAt = "run_started_at"
        case createdAt = "created_at"
        case htmlUrl = "html_url"
        case displayTitle = "display_title"
    }
}

private struct WorkflowNode: Decodable {
    /// `active`・`deleted`・`disabled_fork`・`disabled_inactivity`・`disabled_manually`
    let state: String
}
