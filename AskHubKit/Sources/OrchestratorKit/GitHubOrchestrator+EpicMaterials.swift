import AskHubKit
import Foundation

extension GitHubOrchestrator {
    public func epicMaterials(in repository: String, branch: String) async throws -> EpicMaterials {
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "base", value: branch)],
            of: EpicChildPullRequest.self
        )
        func item(_ pull: EpicChildPullRequest) -> EpicMaterials.Item {
            .init(number: pull.number, title: pull.title)
        }
        let merged = pulls.filter { $0.mergedAt != nil }.sorted { $0.number < $1.number }.map(item)
        let open = pulls.filter { $0.state == "open" }.sorted { $0.number < $1.number }.map(item)
        return EpicMaterials(
            mergedPullRequests: merged,
            openPullRequests: open,
            decisionLogs: try await openIssues(in: repository, label: AskHubLabel.decisionLog.rawValue, mentioning: branch),
            verifyIssues: try await openIssues(in: repository, label: AskHubLabel.needsVerify.rawValue, mentioning: branch)
        )
    }

    /// `label` の付いた open な Issue のうち、タイトルか本文で `branch` に触れているもの
    private func openIssues(in repository: String, label: String, mentioning branch: String) async throws -> [EpicMaterials.Item] {
        let issues = try await client.getAllPages(
            "repos/\(repository)/issues",
            query: [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "labels", value: label)],
            of: EpicRelatedIssue.self
        )
        // Issue の API は PR も返すので除く
        return issues
            .filter { $0.pullRequest == nil && ($0.title.contains(branch) || ($0.body ?? "").contains(branch)) }
            .sorted { $0.number < $1.number }
            .map { .init(number: $0.number, title: $0.title) }
    }
}

private struct EpicChildPullRequest: Decodable {
    let number: Int
    let title: String
    let state: String
    let mergedAt: Date?

    enum CodingKeys: String, CodingKey {
        case number, title, state
        case mergedAt = "merged_at"
    }
}

private struct EpicRelatedIssue: Decodable {
    struct PullRequestLink: Decodable {}

    let number: Int
    let title: String
    let body: String?
    let pullRequest: PullRequestLink?

    enum CodingKeys: String, CodingKey {
        case number, title, body
        case pullRequest = "pull_request"
    }
}
