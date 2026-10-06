import Foundation

// 担当の印（ラベル askhub-orchestrator）を一緒に読む取得
extension GitHubInboxSource {
    /// organization のリポジトリの担当の印を読み、担当 PC が利用上限で待機しているものを返す。
    /// 検索ではなく `organization.repositories` を最後のページまでたどる（検索の件数のずれ・レート制限が無い）
    public func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        var repositories: [UsageLimitedRepository] = []
        // レート制限を考えて、organization ごとに順番に取得する
        for org in orgs {
            repositories += try await usageLimitedRepositories(org: org, now: now)
        }
        return repositories.sorted { ($0.until, $0.repository) < ($1.until, $1.repository) }
    }

    private func usageLimitedRepositories(org: String, now: Date) async throws -> [UsageLimitedRepository] {
        let nodes: [UsageLimitRepositoryNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.usageLimitQuery,
                variables: [
                    "org": .string(org),
                    "after": after.map(GraphQLVariable.string) ?? .null,
                    "label": .string(OrchestratorHeartbeat.labelName)
                ],
                as: UsageLimitData.self
            )
            guard let repositories = data.organization?.repositories else {
                throw GitHubError.invalidResponse
            }
            return (repositories.nodes.compactMap(\.self), repositories.pageInfo)
        }
        return nodes.compactMap { node in
            let description = node.label?.description
            // 担当の印が古い（担当 PC がいない）なら、待機の表示も信じない
            guard OrchestratorHeartbeat.isAssigned(lastSeen: OrchestratorHeartbeat.lastSeen(in: description), now: now),
                  let until = OrchestratorHeartbeat.usageLimitedUntil(in: description),
                  OrchestratorHeartbeat.isUsageLimited(until: until, now: now) else {
                return nil
            }
            return UsageLimitedRepository(repository: node.nameWithOwner, until: until)
        }
    }

    /// 検索結果のリポジトリから、担当の印のラベルも一緒に読む（検索 1 回で済ませる）
    static let waitingQuery = """
        query($query: String!, $after: String, $label: String!) {
          search(query: $query, type: DISCUSSION, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Discussion {
                id number title url closed
                author { login }
                repository { nameWithOwner label(name: $label) { description } }
              }
            }
          }
        }
        """

    private static let usageLimitQuery = """
        query($org: String!, $after: String, $label: String!) {
          organization(login: $org) {
            repositories(first: 100, after: $after, isArchived: false) {
              pageInfo { hasNextPage endCursor }
              nodes { nameWithOwner label(name: $label) { description } }
            }
          }
        }
        """
}

private struct UsageLimitData: Decodable {
    struct Organization: Decodable {
        let repositories: Repositories
    }

    struct Repositories: Decodable {
        let pageInfo: GraphQLPageInfo
        /// GitHub の GraphQL は要素が `null` になりうる
        let nodes: [UsageLimitRepositoryNode?]
    }

    let organization: Organization?
}

private struct UsageLimitRepositoryNode: Decodable {
    struct Label: Decodable {
        let description: String?
    }

    let nameWithOwner: String
    let label: Label?
}
