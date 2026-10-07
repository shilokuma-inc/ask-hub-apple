import Foundation
@testable import OrchestratorKit

// FakeGitHub の、Discussion へのコメントと最終 PR のコンフリクトまわり
extension FakeGitHub {
    var discussionComments: [String] {
        state.withLock { $0.discussionComments }
    }

    func comment(on discussion: ReadyDiscussion, body: String) async throws {
        state.withLock { $0.discussionComments.append("\(discussion.nodeID): \(body)") }
    }

    func setConflictingPullRequests(_ pullRequests: [ConflictingPullRequest]) {
        state.withLock { $0.conflictingPullRequests = pullRequests }
    }

    var pullRequestComments: [String] {
        state.withLock { $0.pullRequestComments }
    }

    func conflictingEpicFinalPullRequests(orgs: [String]) async throws -> [ConflictingPullRequest] {
        state.withLock { $0.conflictingPullRequests }
    }

    func comment(onPullRequest number: Int, in repository: String, body: String) async throws {
        state.withLock { $0.pullRequestComments.append("\(repository)#\(number): \(body)") }
    }
}
