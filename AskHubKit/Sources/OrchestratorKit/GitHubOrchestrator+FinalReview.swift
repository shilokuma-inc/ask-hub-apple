import AskHubKit
import Foundation

extension TrustDirectory: TrustedAuthorsResolving {
    /// ポーリングのはじめに求めておいた、そのリポジトリで信用する author
    public func trustedAuthors(for repository: String) async -> TrustedAuthors {
        authors(for: repository)
    }
}

extension GitHubOrchestrator {
    /// 第三者レビューの対象を決めるための最終 PR（`epic-final`）。アプリのマージ待ちと同じ取得（`GitHubMergeQueue`）を使い、
    /// 信用する author が作った PR の、今の head の CodeRabbit の状態と、信用する author が書いた今の head の第三者レビューを読む
    public func finalReviewCandidates(orgs: [String], trust: TrustDirectory) async throws -> [FinalReviewCandidate] {
        let pullRequests = try await GitHubMergeQueue(client: client, trustedAuthors: trust).epicPullRequests(orgs: orgs)
        return pullRequests.map { pullRequest in
            FinalReviewCandidate(
                pullRequest: FinalReviewPullRequest(
                    repository: pullRequest.repository,
                    number: pullRequest.number,
                    headBranch: pullRequest.headBranch,
                    baseBranch: pullRequest.baseBranch,
                    headSHA: pullRequest.headSHA
                ),
                codeRabbit: pullRequest.codeRabbit,
                // GitHub がまだコンフリクトの有無を判定していない PR も、判定してから扱う
                isConflicting: pullRequest.mergeability != .mergeable,
                thirdPartyReview: pullRequest.thirdPartyReview,
                headSince: pullRequest.headSince
            )
        }
        .sorted { ($0.pullRequest.repository, $0.pullRequest.number) < ($1.pullRequest.repository, $1.pullRequest.number) }
    }
}
