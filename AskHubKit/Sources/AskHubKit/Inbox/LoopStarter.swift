import Foundation

/// Discussion の回答を確定し、ループを始めてよい印（`ready-for-loop`）を付ける。テストでは差し替える
public protocol LoopStarting: Sendable {
    /// Discussion に `ready-for-loop` を付ける。既に付いていても失敗しない
    func markReadyForLoop(_ discussion: InboxSubject) async throws
}

/// ループを始める印を付けられないときのエラー
public enum LoopStartingError: Error, Equatable, Sendable {
    /// Discussion 以外（PR など）には付けない
    case notDiscussion
}

/// GitHub の API で `ready-for-loop` を付ける（Discussion #1 の Q3）
public struct GitHubLoopStarter: LoopStarting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func markReadyForLoop(_ discussion: InboxSubject) async throws {
        guard discussion.kind == .discussion else {
            throw LoopStartingError.notDiscussion
        }
        let labelID = try await readyLabelID(in: discussion.repository)
        // Discussion のラベルは REST で付けられないため GraphQL で付ける
        _ = try await client.graphQL(
            Self.addLabelMutation,
            variables: ["labelable": .string(discussion.nodeID), "labels": .strings([labelID])],
            as: AddLabelsData.self
        )
    }

    /// リポジトリの `ready-for-loop` ラベルの node id。無ければ作る
    private func readyLabelID(in repository: String) async throws -> String {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let label = AskHubLabel.readyForLoop.rawValue
        let data = try await client.graphQL(
            Self.labelQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "label": .string(label)],
            as: LabelLookup.self
        )
        if let id = data.repository?.label?.id {
            return id
        }
        let created = try await client.send(
            "POST",
            "repos/\(repository)/labels",
            body: NewLabel(name: label, color: "0e8a16", description: "回答が確定し、ループを始めてよい（AskHub）"),
            as: CreatedLabel.self
        )
        return created.nodeID
    }

    private static let labelQuery = """
        query($owner: String!, $name: String!, $label: String!) {
          repository(owner: $owner, name: $name) { label(name: $label) { id } }
        }
        """

    private static let addLabelMutation = """
        mutation($labelable: ID!, $labels: [ID!]!) {
          addLabelsToLabelable(input: { labelableId: $labelable, labelIds: $labels }) { clientMutationId }
        }
        """
}

private struct LabelLookup: Decodable {
    struct Repository: Decodable {
        let label: LabelNodeID?
    }

    let repository: Repository?
}

private struct LabelNodeID: Decodable {
    let id: String
}

private struct NewLabel: Encodable, Sendable {
    let name: String
    let color: String
    let description: String
}

private struct CreatedLabel: Decodable {
    let nodeID: String

    private enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
    }
}

private struct AddLabelsData: Decodable {
    struct Payload: Decodable {
        let clientMutationId: String?
    }

    let addLabelsToLabelable: Payload?
}
