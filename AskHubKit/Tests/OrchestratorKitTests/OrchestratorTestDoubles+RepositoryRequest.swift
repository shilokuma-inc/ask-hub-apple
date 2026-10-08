@testable import OrchestratorKit

// FakeGitHub の、担当リポジトリの作成・削除の依頼（`repo-request`）に使う操作

extension FakeGitHub {
    func setRepositoryRequests(_ issues: [RepositoryRequestIssue]) {
        state.withLock { $0.repositoryRequests = issues }
    }

    func repositoryRequests(orgs: [String]) async throws -> [RepositoryRequestIssue] {
        state.withLock { $0.repositoryRequests }.filter { Self.isInside(orgs, $0.repository) }
    }

    var deletedHeartbeats: [String] {
        state.withLock { $0.deletedHeartbeats }
    }

    func deleteHeartbeat(in repository: String) async throws {
        state.withLock { $0.deletedHeartbeats.append(repository) }
    }
}
