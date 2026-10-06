import Foundation

/// GitHub の GraphQL API から、リポジトリごとの担当の印と状態用の Issue を取得する。
///
/// 検索ではなく `organization.repositories` を最後のページまでたどる（Search API の 30 回/分の制限と、検索の件数のずれを避ける）。
/// 状態用の Issue はリポジトリに 1 つの想定だが、誰でも同じラベルで作れるので、1 ページに収まらなければそのリポジトリだけ続きを取る
public struct GitHubLoopStatusSource: LoopStatusSource {
    let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
        let nodes: [RepositoryNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.repositoriesQuery,
                variables: [
                    "org": .string(org),
                    "after": after.map(GraphQLVariable.string) ?? .null,
                    "label": .string(OrchestratorHeartbeat.labelName),
                    "statusLabel": .string(LoopStatusReport.labelName)
                ],
                as: RepositoriesData.self
            )
            guard let repositories = data.organization?.repositories else {
                throw GitHubError.invalidResponse
            }
            return (repositories.nodes.compactMap(\.self), repositories.pageInfo)
        }
        var repositories: [LoopStatusRepository] = []
        // レート制限を考えて、続きのあるリポジトリは順番に取得する
        for node in nodes {
            var issues = node.issues?.nodes.compactMap(\.self) ?? []
            if let pageInfo = node.issues?.pageInfo, pageInfo.hasNextPage {
                issues += try await remainingIssues(of: node.nameWithOwner, after: pageInfo.endCursor)
            }
            repositories.append(LoopStatusRepository(
                repository: node.nameWithOwner,
                heartbeatDescription: node.label?.description,
                issues: issues.compactMap(\.issue)
            ))
        }
        return repositories
    }

    /// 1 ページ目に収まらなかった状態用の Issue の続き
    private func remainingIssues(of repository: String, after cursor: String?) async throws -> [IssueNode] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let cursor else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            // 1 回目（`after` が `nil`）は、リポジトリの一覧で取った 1 ページ目の続きから
            let data = try await client.graphQL(
                Self.issuesQuery,
                variables: [
                    "owner": .string(parts[0]),
                    "name": .string(parts[1]),
                    "after": .string(after ?? cursor),
                    "statusLabel": .string(LoopStatusReport.labelName)
                ],
                as: IssuesData.self
            )
            guard let issues = data.repository?.issues else {
                throw GitHubError.invalidResponse
            }
            return (issues.nodes.compactMap(\.self), issues.pageInfo)
        }
    }

    /// 本文は状態の目印と短い表だけなので、まとめて取っても大きくならない
    private static let issueFields = """
        pageInfo { hasNextPage endCursor }
        nodes { number url updatedAt body author { login } }
        """

    static let repositoriesQuery = """
        query($org: String!, $after: String, $label: String!, $statusLabel: String!) {
          organization(login: $org) {
            repositories(first: 50, after: $after, isArchived: false) {
              pageInfo { hasNextPage endCursor }
              nodes {
                nameWithOwner
                label(name: $label) { description }
                issues(first: 20, states: OPEN, labels: [$statusLabel], orderBy: { field: UPDATED_AT, direction: DESC }) {
                  \(issueFields)
                }
              }
            }
          }
        }
        """

    static let issuesQuery = """
        query($owner: String!, $name: String!, $after: String, $statusLabel: String!) {
          repository(owner: $owner, name: $name) {
            issues(first: 100, after: $after, states: OPEN, labels: [$statusLabel], orderBy: { field: UPDATED_AT, direction: DESC }) {
              \(issueFields)
            }
          }
        }
        """
}

private struct RepositoriesData: Decodable {
    struct Organization: Decodable {
        let repositories: Repositories
    }

    struct Repositories: Decodable {
        let pageInfo: GraphQLPageInfo
        /// GitHub の GraphQL は要素が `null` になりうる
        let nodes: [RepositoryNode?]
    }

    let organization: Organization?
}

private struct RepositoryNode: Decodable {
    struct Label: Decodable {
        let description: String?
    }

    let nameWithOwner: String
    let label: Label?
    let issues: IssueConnection?
}

private struct IssuesData: Decodable {
    struct Repository: Decodable {
        let issues: IssueConnection
    }

    let repository: Repository?
}

private struct IssueConnection: Decodable {
    let pageInfo: GraphQLPageInfo
    let nodes: [IssueNode?]
}

private struct IssueNode: Decodable {
    struct Author: Decodable {
        let login: String
    }

    let number: Int?
    let url: URL?
    let updatedAt: Date?
    let body: String?
    let author: Author?

    var issue: LoopStatusIssue? {
        guard let number, let url, let updatedAt, let body else {
            return nil
        }
        return LoopStatusIssue(number: number, url: url, author: author?.login, updatedAt: updatedAt, body: body)
    }
}
