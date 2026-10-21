import AskHubKit
import Foundation
@testable import OrchestratorKit

/// 添付の片付け（Discussion #669 の Q7）の差し替えの状態
struct FakeAttachmentCleanupState {
    var mergedPullRequests: [MergedEpicFinalPullRequest] = []
    /// マージ済みの最終 PR を探した回数
    var mergedFetches = 0
    /// Discussion の番号 → 本文・コメント・返信
    var discussionTexts: [Int: [AuthoredText]] = [:]
    /// epic ブランチ → 子 PR のレビューコメント
    var reviewComments: [String: [AuthoredText]] = [:]
    /// `askhub/attachments` にあるパス。`nil` ならブランチが無い
    var branchPaths: Set<String>? = []
    /// 消したパス（呼ばれた順）
    var deleted: [[String]] = []
    /// 次の削除で ref の更新が競合する回数
    var conflicts = 0
}

extension FakeGitHub {
    func setMergedEpicFinalPullRequests(_ pulls: [MergedEpicFinalPullRequest]) {
        cleanup.withLock { $0.mergedPullRequests = pulls }
    }

    func setDiscussionTexts(_ texts: [AuthoredText], for number: Int) {
        cleanup.withLock { $0.discussionTexts[number] = texts }
    }

    func setReviewComments(_ texts: [AuthoredText], base branch: String) {
        cleanup.withLock { $0.reviewComments[branch] = texts }
    }

    func setAttachmentBranchPaths(_ paths: Set<String>?) {
        cleanup.withLock { $0.branchPaths = paths }
    }

    func setDeleteConflicts(_ count: Int) {
        cleanup.withLock { $0.conflicts = count }
    }

    var deletedAttachments: [[String]] {
        cleanup.withLock { $0.deleted }
    }

    var mergedFinalPullRequestFetches: Int {
        cleanup.withLock { $0.mergedFetches }
    }

    func mergedEpicFinalPullRequests(in repository: String) async throws -> [MergedEpicFinalPullRequest] {
        cleanup.withLock { state in
            state.mergedFetches += 1
            return state.mergedPullRequests.filter { $0.repository == repository }
        }
    }

    func discussionTexts(in repository: String, number: Int) async throws -> [AuthoredText] {
        cleanup.withLock { $0.discussionTexts[number] ?? [] }
    }

    func childPullRequestReviewComments(in repository: String, base branch: String) async throws -> [AuthoredText] {
        cleanup.withLock { $0.reviewComments[branch] ?? [] }
    }

    func deleteAttachments(at paths: [String], in repository: String) async throws -> Int {
        try cleanup.withLock { state in
            guard let existing = state.branchPaths else {
                return 0
            }
            if state.conflicts > 0 {
                state.conflicts -= 1
                throw AttachmentCleanupError.conflict
            }
            let targets = paths.filter { existing.contains($0) }
            guard !targets.isEmpty else {
                return 0
            }
            state.deleted.append(targets)
            state.branchPaths = existing.subtracting(targets)
            return targets.count
        }
    }
}
