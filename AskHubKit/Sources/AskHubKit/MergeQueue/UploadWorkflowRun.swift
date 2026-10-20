import Foundation

/// Upload ワークフローの run の取得と起動。テストでは差し替える
public protocol UploadWorkflowProviding: Sendable {
    /// `repository`（`owner/repo`）の `branch` で実行した Upload ワークフローの直近の run
    func latestRun(repository: String, branch: String) async throws -> LatestUploadRun
    /// `repository` の Upload ワークフローを `ref`（最終 PR の head ブランチ）で起動する（`workflow_dispatch`）。
    /// 起動の直後は run の一覧に新しい run がすぐには出ないので、呼び出し側は「起動した」状態を保つ
    func dispatch(repository: String, ref: String) async throws
}

/// GitHub の REST API で Upload ワークフロー（`upload.yml`）の run を読み、起動する（Discussion #449）。
/// 中身は `GitHubWorkflow` に任せ、入力（inputs）は送らない（`upload.yml` はブランチの選択だけで動く）
public struct GitHubUploadWorkflow: UploadWorkflowProviding {
    /// ワークフローのファイル名。API の `workflow_id` にはファイル名をそのまま使える
    public static let workflowFile = "upload.yml"

    private let workflow: GitHubWorkflow

    /// - Parameter workflowFile: ワークフローのファイル名。既定は `upload.yml`
    public init(client: GitHubClient, workflowFile: String = Self.workflowFile) {
        workflow = GitHubWorkflow(client: client, file: workflowFile)
    }

    public func latestRun(repository: String, branch: String) async throws -> LatestUploadRun {
        try await workflow.latestRun(repository: repository, branch: branch)
    }

    public func dispatch(repository: String, ref: String) async throws {
        try await workflow.dispatch(repository: repository, ref: ref)
    }
}
