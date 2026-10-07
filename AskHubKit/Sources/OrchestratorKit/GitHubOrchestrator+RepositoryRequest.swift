import AskHubKit
import Foundation

/// 担当リポジトリの作成・削除の依頼（`repo-request`）に使う GitHub の操作
extension GitHubOrchestrator {
    public func repositoryRequests(orgs: [String]) async throws -> [RepositoryRequestIssue] {
        try await requestIssues(labeled: .repoRequest, orgs: orgs)
    }

    public func deleteHeartbeat(in repository: String) async throws {
        do {
            try await client.send("DELETE", "repos/\(repository)/labels/\(OrchestratorHeartbeat.labelName)")
        } catch GitHubError.http(status: 404, _) {
            // 既に無い
        }
    }
}
