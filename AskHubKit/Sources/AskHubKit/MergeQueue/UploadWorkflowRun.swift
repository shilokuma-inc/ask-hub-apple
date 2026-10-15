import Foundation

/// Upload ワークフロー（`upload.yml`）の run。最終 PR の epic ブランチを TestFlight に上げたときの状態を出すために使う
/// （Discussion #449 の Q4）
public struct UploadWorkflowRun: Sendable, Equatable, Hashable, Identifiable {
    /// GitHub の `status`。知らない値は `other`
    public enum Status: Sendable, Equatable, Hashable {
        case queued
        case inProgress
        case completed
        /// `waiting`・`requested`・`pending` など、まだ完了していないその他の状態
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "queued":
                self = .queued

            case "in_progress":
                self = .inProgress

            case "completed":
                self = .completed

            default:
                self = .other(rawValue)
            }
        }
    }

    /// GitHub の `conclusion`（`status` が `completed` のときだけ入る）。知らない値は `other`
    public enum Conclusion: Sendable, Equatable, Hashable {
        case success
        case failure
        case cancelled
        /// `skipped`・`timed_out`・`action_required`・`startup_failure` など
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "success":
                self = .success

            case "failure":
                self = .failure

            case "cancelled":
                self = .cancelled

            default:
                self = .other(rawValue)
            }
        }
    }

    /// run の id
    public var id: Int
    /// `owner/repo`
    public var repository: String
    /// 実行したブランチ（`head_branch`）
    public var branch: String
    /// ビルドしたコミット（`head_sha`）。PR の最新の head と同じかを見るために使う
    public var headSHA: String
    public var status: Status
    public var conclusion: Conclusion?
    /// 起動のきっかけ（`workflow_dispatch` / `push` など）
    public var event: String
    /// 開始時刻（`run_started_at`。無ければ `created_at`）
    public var startedAt: Date
    /// GitHub の run ページ
    public var url: URL

    public init(
        id: Int,
        repository: String,
        branch: String,
        headSHA: String,
        status: Status,
        conclusion: Conclusion?,
        event: String,
        startedAt: Date,
        url: URL
    ) {
        self.id = id
        self.repository = repository
        self.branch = branch
        self.headSHA = headSHA
        self.status = status
        self.conclusion = conclusion
        self.event = event
        self.startedAt = startedAt
        self.url = url
    }

    /// まだ終わっていないか（queued / in_progress / waiting など）。実行中はもう一度上げられない
    public var isRunning: Bool {
        status != .completed
    }

    /// 成功して終わったか
    public var isSuccessful: Bool {
        status == .completed && conclusion == .success
    }

    /// ビルドしたコミットが、PR の最新の head と同じか
    public func builtHead(_ sha: String) -> Bool {
        headSHA.caseInsensitiveCompare(sha) == .orderedSame
    }
}

/// Upload ワークフローの直近の run の問い合わせの結果
public enum LatestUploadRun: Sendable, Equatable, Hashable {
    /// ワークフロー（`upload.yml`）がリポジトリに無い（404）。ボタンを出さない
    case unsupported
    /// ワークフローはあるが、このブランチの run がまだ無い
    case none
    /// 直近の run
    case run(UploadWorkflowRun)

    /// 直近の run（無ければ `nil`）
    public var run: UploadWorkflowRun? {
        if case .run(let run) = self {
            return run
        }
        return nil
    }
}

/// Upload ワークフローの操作で起きるエラー。`GitHubError` の HTTP の状態から、アプリで表示を分けるものを区別する
public enum UploadWorkflowError: Error, Equatable, Sendable {
    /// トークンに Actions の権限（Fine-grained PAT の Actions: Read and write）が無い。
    /// レート制限の 403（`x-ratelimit-remaining: 0`・`Retry-After`）は `GitHubError.rateLimited` のままで、ここには来ない
    case permissionDenied
}

/// Upload ワークフローの run の取得。テストでは差し替える
public protocol UploadWorkflowProviding: Sendable {
    /// `repository`（`owner/repo`）の `branch` で実行した Upload ワークフローの直近の run
    func latestRun(repository: String, branch: String) async throws -> LatestUploadRun
}

/// GitHub の REST API で Upload ワークフローの run を読む
public struct GitHubUploadWorkflow: UploadWorkflowProviding {
    /// ワークフローのファイル名。API の `workflow_id` にはファイル名をそのまま使える
    public static let workflowFile = "upload.yml"

    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func latestRun(repository: String, branch: String) async throws -> LatestUploadRun {
        // 直近の 1 件だけが要るので、ページングはせず per_page を 1 にする（run は新しい順に返る）。
        // branch で絞ると push と workflow_dispatch の両方の run が返る。どちらも対象にする
        let page: RunsPage
        do {
            page = try await client.get(
                "repos/\(repository)/actions/workflows/\(Self.workflowFile)/runs",
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
            throw UploadWorkflowError.permissionDenied
        }
        guard let run = page.workflowRuns.first else {
            return .none
        }
        return .run(UploadWorkflowRun(
            id: run.id,
            repository: repository,
            branch: run.headBranch ?? branch,
            headSHA: run.headSha,
            status: .init(rawValue: run.status),
            conclusion: run.conclusion.map(UploadWorkflowRun.Conclusion.init(rawValue:)),
            event: run.event,
            startedAt: run.runStartedAt ?? run.createdAt,
            url: run.htmlUrl
        ))
    }
}

// MARK: - レスポンスの形

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
    let status: String
    let conclusion: String?
    let event: String
    let runStartedAt: Date?
    let createdAt: Date
    let htmlUrl: URL

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
    }
}
