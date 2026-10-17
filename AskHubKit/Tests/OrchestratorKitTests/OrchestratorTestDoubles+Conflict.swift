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

    func comment(onPullRequest number: Int, in repository: String, body: String) async throws {
        state.withLock { $0.pullRequestComments.append("\(repository)#\(number): \(body)") }
    }
}

// FakeGitHub の、最終 PR の第三者レビューの対象
extension FakeGitHub {
    func setFinalReviewCandidates(_ candidates: [FinalReviewCandidate]) {
        state.withLock { $0.finalReviewCandidates = candidates }
    }

    func finalReviewCandidates(orgs: [String], trust: TrustDirectory) async throws -> [FinalReviewCandidate] {
        state.withLock { $0.finalReviewCandidates }
    }
}

// FakeGitHub の、最終 PR の状態コメント。作ったコメントは次の取得（comments(in:issue:)）で返る
extension FakeGitHub {
    func setIssueComments(_ comments: [IssueComment], issue number: Int) {
        state.withLock { $0.issueComments[number] = comments }
    }

    var updatedComments: [String] {
        state.withLock { $0.updatedComments }
    }

    func createComment(onPullRequest number: Int, in repository: String, body: String) async throws -> Int {
        state.withLock { state in
            let id = 7_000 + state.issueComments.values.joined().count
            state.issueComments[number, default: []].append(IssueComment(id: id, author: "mrs1669", body: body))
            state.createdComments.append("\(repository)#\(number) \(id)")
            return id
        }
    }

    /// その id のコメントの書き換えを、HTTP の状態コードで失敗させる（消された・権限が無い）
    func setCommentUpdateFailure(id: Int, status: Int, message: String? = nil) {
        state.withLock { $0.commentUpdateFailures[id] = (status, message) }
    }

    func updateComment(in repository: String, id: Int, body: String) async throws {
        try state.withLock { state in
            if let failure = state.commentUpdateFailures[id] {
                throw GitHubError.http(status: failure.status, message: failure.message)
            }
            for (number, comments) in state.issueComments {
                if let index = comments.firstIndex(where: { $0.id == id }) {
                    let old = comments[index]
                    state.issueComments[number]?[index] = IssueComment(id: id, author: old.author, body: body)
                }
            }
            state.updatedComments.append("\(repository) \(id)")
        }
    }

    var createdComments: [String] {
        state.withLock { $0.createdComments }
    }
}
