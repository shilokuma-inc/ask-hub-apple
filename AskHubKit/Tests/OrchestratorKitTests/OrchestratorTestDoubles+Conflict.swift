import AskHubKit
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

    /// コメントは、次の取得で返るように Issue のコメントにも足す
    func comment(onPullRequest number: Int, in repository: String, body: String) async throws {
        try state.withLock { state in
            if state.pullRequestCommentFails {
                throw TestError()
            }
            state.pullRequestComments.append("\(repository)#\(number): \(body)")
            let id = 900_000 + state.pullRequestComments.count
            state.issueComments[number, default: []].append(IssueComment(id: id, author: "mrs1669", body: body))
        }
    }

    func setPullRequestCommentFails(_ fails: Bool) {
        state.withLock { $0.pullRequestCommentFails = fails }
    }

    func setFailingPullRequests(_ pullRequests: [FailingPullRequest]) {
        state.withLock { $0.failingPullRequests = pullRequests }
    }

    func failingEpicFinalPullRequests(orgs: [String], trust: TrustDirectory) async throws -> [FailingPullRequest] {
        state.withLock { $0.failingPullRequests }
    }
}
