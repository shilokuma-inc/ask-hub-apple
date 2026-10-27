import AskHubKit
import Foundation

/// 担当リポジトリの移管・改名への追従（Issue #757）に使う GitHub の操作
extension GitHubOrchestrator {
    /// GraphQL の `repository(owner:, name:)` は旧名でも移管・改名の後のリポジトリを返す。
    /// REST の `repos/{owner}/{repo}` は旧名だとリダイレクトになり、送り直しで `Authorization` が外れる
    /// （2026-10-26 の移管では、書き込みが 401・読み取りが未認証のレート制限になった）ため使わない
    public func currentName(of repository: String) async throws -> String {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let data = try await client.graphQL(
            Self.repositoryNameQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1])],
            as: RepositoryNameData.self
        )
        guard let name = data.repository?.nameWithOwner else {
            throw GitHubError.invalidResponse
        }
        return name
    }

    static let repositoryNameQuery = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) { nameWithOwner }
        }
        """
}

private struct RepositoryNameData: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
    }

    let repository: Repository?
}
