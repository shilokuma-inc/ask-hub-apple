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

    var closedLoopStatusIssues: [String] {
        state.withLock { $0.closedLoopStatusIssues }
    }

    func closeLoopStatusIssue(in repository: String, number: Int) async throws {
        state.withLock { state in
            state.closedLoopStatusIssues.append("\(repository)#\(number)")
            if let issue = state.loopStatusIssues[number] {
                state.loopStatusIssues[number] = LoopStatusIssueRecord(
                    number: number, author: issue.author, isOpen: false, updatedAt: issue.updatedAt, body: issue.body
                )
            }
        }
    }

    func deleteHeartbeat(in repository: String) async throws {
        state.withLock { $0.deletedHeartbeats.append(repository) }
    }
}
