import AskHubKit
import Foundation

extension GitHubOrchestrator {
    public func epicFinalPullRequests(in repository: String) async throws -> [EpicFinalPullRequest] {
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [URLQueryItem(name: "state", value: "open")],
            of: OpenPullRequestSummary.self
        )
        return pulls
            .filter { $0.labels.contains { $0.name == AskHubLabel.epicFinal.rawValue } }
            .map { EpicFinalPullRequest(repository: repository, number: $0.number, headBranch: $0.head.ref, author: $0.user?.login) }
    }
}

private struct OpenPullRequestSummary: Decodable {
    struct Ref: Decodable {
        let ref: String
    }

    struct User: Decodable {
        let login: String
    }

    struct Label: Decodable {
        let name: String
    }

    let number: Int
    let head: Ref
    /// 削除済みのユーザーでは `nil`
    let user: User?
    let labels: [Label]
}
