import AskHubKit
import Foundation

/// 担当リポジトリの作成・追加・削除の依頼（`repo-request`）に使う GitHub の操作
extension GitHubOrchestrator {
    public func repositoryRequests(orgs: [String]) async throws -> [RepositoryRequestIssue] {
        try await requestIssues(labeled: .repoRequest, orgs: orgs)
    }

    public func closeLoopStatusIssue(in repository: String, number: Int) async throws {
        try await client.send("PATCH", "repos/\(repository)/issues/\(number)", body: ["state": "closed"], as: ClosedIssue.self)
    }

    public func deleteHeartbeat(in repository: String) async throws {
        do {
            try await client.send("DELETE", "repos/\(repository)/labels/\(OrchestratorHeartbeat.labelName)")
        } catch GitHubError.http(status: 404, _) {
            // 既に無い
        }
    }

    public func heartbeatLastSeen(in repository: String) async throws -> Date? {
        let label: HeartbeatLabel
        do {
            label = try await client.get("repos/\(repository)/labels/\(OrchestratorHeartbeat.labelName)")
        } catch GitHubError.http(status: 404, _) {
            // 一度も担当になっていない（リポジトリを読めないときも 404 になるが、それは担当に入れるコマンドが断る）
            return nil
        }
        return OrchestratorHeartbeat.lastSeen(in: label.description)
    }
}

private struct HeartbeatLabel: Decodable {
    let description: String?
}

private struct ClosedIssue: Decodable {
    let number: Int
}
