import AskHubKit
import Foundation

/// GitHub の GraphQL API でオーケストレーターの操作を行う
public struct GitHubOrchestrator: OrchestratorGitHub {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion] {
        let label = AskHubLabel.readyForLoop.rawValue
        // 担当リポジトリごとではなく org 全体を 1 回で検索する（Search API のレート制限のため）
        let nodes: [SearchNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.searchQuery,
                variables: ["query": .string("org:\(org) label:\(label)"), "after": after.map(GraphQLVariable.string) ?? .null],
                as: SearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            // 検索の型に合わないノードは `{}` で返る。closed の Discussion は扱わない
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let repository = node.repository?.nameWithOwner, node.closed == false,
                  let labelID = node.labelID(named: label) else {
                return nil
            }
            return ReadyDiscussion(
                nodeID: id,
                repository: repository,
                number: number,
                title: title,
                url: url,
                author: node.author?.login,
                readyLabelID: labelID
            )
        }
    }

    public func removeReadyLabel(from discussion: ReadyDiscussion) async throws {
        _ = try await client.graphQL(
            Self.removeLabelMutation,
            variables: ["labelable": .string(discussion.nodeID), "labels": .strings([discussion.readyLabelID])],
            as: RemoveLabelsData.self
        )
    }

    private static let searchQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: DISCUSSION, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Discussion {
                id number title url closed
                author { login }
                repository { nameWithOwner }
                labels(first: 100) { nodes { id name } }
              }
            }
          }
        }
        """

    private static let removeLabelMutation = """
        mutation($labelable: ID!, $labels: [ID!]!) {
          removeLabelsFromLabelable(input: { labelableId: $labelable, labelIds: $labels }) { clientMutationId }
        }
        """
}

// MARK: - レスポンスの形

private struct SearchData: Decodable {
    let search: Connection<SearchNode>
}

private struct Connection<Node: Decodable>: Decodable {
    let pageInfo: GraphQLPageInfo
    /// GitHub の GraphQL は要素が `null` になりうる
    let nodes: [Node?]
}

private struct SearchNode: Decodable {
    struct Author: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Label: Decodable {
        let id: String
        let name: String
    }

    struct Labels: Decodable {
        let nodes: [Label?]
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let closed: Bool?
    let author: Author?
    let repository: Repository?
    let labels: Labels?

    /// ラベルの node id。GitHub のラベル名は大文字・小文字を区別しない
    func labelID(named name: String) -> String? {
        labels?.nodes.compactMap(\.self).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}

private struct RemoveLabelsData: Decodable {
    struct Payload: Decodable {
        let clientMutationId: String?
    }

    let removeLabelsFromLabelable: Payload?
}
