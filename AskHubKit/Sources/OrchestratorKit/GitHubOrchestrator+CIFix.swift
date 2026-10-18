import AskHubKit
import Foundation

extension GitHubOrchestrator {
    /// 「マージ待ち」と同じ取得（`GitHubMergeQueue`）で、CI（GitHub Actions の check run）が失敗し、すべて終わった最終 PR を返す。
    /// 信用する author が作った、同じリポジトリの epic ブランチから既定ブランチへの PR だけ。
    /// コンフリクトしている PR は、先に解消させるので除く（解消の push で CI が回り直す）
    public func failingEpicFinalPullRequests(orgs: [String], trust: TrustDirectory) async throws -> [FailingPullRequest] {
        try await GitHubMergeQueue(client: client, trustedAuthors: trust)
            .epicPullRequests(orgs: orgs)
            .filter { $0.checks == .failure && !$0.hasRunningChecks && $0.mergeability != .conflicting }
            .map { FailingPullRequest(repository: $0.repository, number: $0.number, headBranch: $0.headBranch, headSHA: $0.headSHA) }
            .sorted { ($0.repository, $0.number) < ($1.repository, $1.number) }
    }
}

extension TrustDirectory: TrustedAuthorsResolving {
    public func trustedAuthors(for repository: String) async -> TrustedAuthors {
        authors(for: repository)
    }
}
