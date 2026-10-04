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
        // 担当リポジトリごとではなく org 全体を 1 回で検索する（Search API のレート制限のため）。
        // 検索結果は 1,000 件までなので、closed の Discussion で上限を埋めないよう検索の段階で open に絞る
        let query = "org:\(org) label:\(label) is:open"
        let nodes: [SearchNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.searchQuery,
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
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

    public func removeNeedsAnswerLabel(from subject: InboxSubject) async throws {
        let parts = subject.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        // Discussion のラベルは REST で外せないため、リポジトリのラベルの node id を引いて GraphQL で外す
        let data = try await client.graphQL(
            Self.labelQuery,
            variables: [
                "owner": .string(parts[0]),
                "name": .string(parts[1]),
                "label": .string(AskHubLabel.needsAnswer.rawValue)
            ],
            as: LabelData.self
        )
        guard let labelID = data.repository?.label?.id else {
            // リポジトリにラベルが無ければ、付いてもいない
            return
        }
        _ = try await client.graphQL(
            Self.removeLabelMutation,
            variables: ["labelable": .string(subject.nodeID), "labels": .strings([labelID])],
            as: RemoveLabelsData.self
        )
    }

    public func hasPullRequest(in repository: String, head branch: String) async throws -> Bool {
        let owner = try Self.owner(of: repository)
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [URLQueryItem(name: "head", value: "\(owner):\(branch)"), URLQueryItem(name: "state", value: "all")],
            of: PullRequestNumber.self
        )
        return !pulls.isEmpty
    }

    public func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int {
        // 統合先は Q13 の develop。リポジトリの既定ブランチとして読む
        let base = try await client.get("repos/\(repository)", as: RepositoryInfo.self).defaultBranch
        let pull = try await client.send(
            "POST",
            "repos/\(repository)/pulls",
            body: NewPullRequest(
                title: Self.epicFinalTitle(branch: branch, base: base),
                head: branch,
                base: base,
                body: body + Self.epicFinalFooter
            ),
            as: PullRequestNumber.self
        )
        // PR のラベルは Issue の API で付ける
        _ = try await client.send(
            "POST",
            "repos/\(repository)/issues/\(pull.number)/labels",
            body: ["labels": [AskHubLabel.epicFinal.rawValue]],
            as: [LabelName].self
        )
        return pull.number
    }

    static func epicFinalTitle(branch: String, base: String) -> String {
        "【FEAT】\(branch) を \(base) に取り込む"
    }

    static let epicFinalFooter = """


        ---
        この PR は askhub-orchestrator が epic の完了を検知して作成しました。
        AskHub アプリの「マージ待ち」から確認して、merge commit でマージしてください。
        """

    private static func owner(of repository: String) throws -> String {
        guard let owner = repository.split(separator: "/").first, !owner.isEmpty else {
            throw GitHubError.invalidResponse
        }
        return String(owner)
    }

    private static let labelQuery = """
        query($owner: String!, $name: String!, $label: String!) {
          repository(owner: $owner, name: $name) { label(name: $label) { id } }
        }
        """

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

private struct LabelData: Decodable {
    struct Repository: Decodable {
        let label: LabelNode?
    }

    let repository: Repository?
}

private struct LabelNode: Decodable {
    let id: String
}

private struct RemoveLabelsData: Decodable {
    struct Payload: Decodable {
        let clientMutationId: String?
    }

    let removeLabelsFromLabelable: Payload?
}

private struct PullRequestNumber: Decodable {
    let number: Int
}

private struct RepositoryInfo: Decodable {
    let defaultBranch: String

    private enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}

private struct NewPullRequest: Encodable, Sendable {
    let title: String
    let head: String
    let base: String
    let body: String
}

private struct LabelName: Decodable {
    let name: String
}
