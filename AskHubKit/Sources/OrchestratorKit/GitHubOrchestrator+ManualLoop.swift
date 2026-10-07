import AskHubKit
import Foundation

/// `manual-loop` が付いた open な Discussion（手で回す epic）
public struct ManualLoopDiscussion: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    /// 削除済みのユーザーでは `nil`
    public let author: String?

    public init(repository: String, number: Int, author: String?) {
        self.repository = repository
        self.number = number
        self.author = author
    }
}

// 手で回す Discussion（manual-loop）の検索
extension GitHubOrchestrator {
    public func manualLoopDiscussions(orgs: [String]) async throws -> [ManualLoopDiscussion] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        // ready-for-loop と同じく organization 全体を 1 回で検索し、検索の段階で open に絞る
        let query = "\(scope) label:\(AskHubLabel.manualLoop.rawValue) is:open"
        let nodes: [ManualLoopSearchNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.manualLoopSearchQuery,
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
                as: ManualLoopSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            // 検索の型に合わないノードは `{}` で返る。closed の Discussion は扱わない
            guard let number = node.number, let repository = node.repository?.nameWithOwner, node.closed == false else {
                return nil
            }
            return ManualLoopDiscussion(repository: repository, number: number, author: node.author?.login)
        }
    }

    private static let manualLoopSearchQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: DISCUSSION, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on Discussion { number closed author { login } repository { nameWithOwner } } }
          }
        }
        """
}

private struct ManualLoopSearchData: Decodable {
    struct Search: Decodable {
        let pageInfo: GraphQLPageInfo
        /// GitHub の GraphQL は要素が `null` になりうる
        let nodes: [ManualLoopSearchNode?]
    }

    let search: Search
}

private struct ManualLoopSearchNode: Decodable {
    struct Author: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    let number: Int?
    let closed: Bool?
    let author: Author?
    let repository: Repository?
}
