import Foundation

/// Discussion の回答を確定し、ループを始めてよい印（`ready-for-loop`）か、手で回す印（`manual-loop`）を付ける。テストでは差し替える
public protocol LoopStarting: Sendable {
    /// Discussion に `ready-for-loop` を付ける。既に付いていても失敗しない
    func markReadyForLoop(_ discussion: InboxSubject) async throws
    /// Discussion に `manual-loop` を付ける（オーケストレーターは起動せず、ループは手で始める）。既に付いていても失敗しない
    func markManualLoop(_ discussion: InboxSubject) async throws
    /// 手動ループの担当者を知らせるコメント（`ManualLoopAssignment`）を Discussion に付ける
    func assignManualLoop(_ discussion: InboxSubject, to login: String) async throws
    /// 手動ループの担当者に選べるアカウント（そのリポジトリに書き込み権限を持つ人）
    func assigneeCandidates(in repository: String) async throws -> [String]
    /// トークンの持ち主の login（担当者の既定と、自分が担当の手動ループの判定に使う）
    func viewerLogin() async throws -> String
}

/// ループを始める印を付けられないときのエラー
public enum LoopStartingError: Error, Equatable, Sendable {
    /// Discussion 以外（PR など）には付けない
    case notDiscussion
    /// 担当者の login の形式が正しくない
    case invalidAssignee
}

/// GitHub の API で `ready-for-loop`（Discussion #1 の Q3）か `manual-loop`（Discussion #273 の Q2）を付ける
public struct GitHubLoopStarter: LoopStarting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func markReadyForLoop(_ discussion: InboxSubject) async throws {
        try await add(.readyForLoop, color: "0e8a16", description: "回答が確定し、ループを始めてよい（AskHub）", to: discussion)
    }

    public func markManualLoop(_ discussion: InboxSubject) async throws {
        try await add(.manualLoop, color: "c5def5", description: "この Discussion のループは手で回す（AskHub）", to: discussion)
    }

    public func assignManualLoop(_ discussion: InboxSubject, to login: String) async throws {
        guard discussion.kind == .discussion else {
            throw LoopStartingError.notDiscussion
        }
        guard ManualLoopAssignment.isValidLogin(login) else {
            throw LoopStartingError.invalidAssignee
        }
        let body = ManualLoopAssignment.comment(assignee: login, repository: discussion.repository, discussionNumber: discussion.number)
        _ = try await client.graphQL(
            Self.addCommentMutation,
            variables: ["discussion": .string(discussion.nodeID), "body": .string(body)],
            as: AddCommentData.self
        )
    }

    public func assigneeCandidates(in repository: String) async throws -> [String] {
        try await GitHubRepositoryWriters(client: client).writers(of: repository)
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    public func viewerLogin() async throws -> String {
        try await client.graphQL("query { viewer { login } }", as: ViewerData.self).viewer.login
    }

    /// Discussion にラベルを付ける。リポジトリに無ければ `color` と `description` で作る
    private func add(_ label: AskHubLabel, color: String, description: String, to discussion: InboxSubject) async throws {
        guard discussion.kind == .discussion else {
            throw LoopStartingError.notDiscussion
        }
        let newLabel = NewLabel(name: label.rawValue, color: color, description: description)
        let labelID = try await labelID(of: newLabel, in: discussion.repository)
        // Discussion のラベルは REST で付けられないため GraphQL で付ける
        _ = try await client.graphQL(
            Self.addLabelMutation,
            variables: ["labelable": .string(discussion.nodeID), "labels": .strings([labelID])],
            as: AddLabelsData.self
        )
    }

    /// リポジトリのラベルの node id。無ければ作る
    private func labelID(of label: NewLabel, in repository: String) async throws -> String {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let data = try await client.graphQL(
            Self.labelQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "label": .string(label.name)],
            as: LabelLookup.self
        )
        if let id = data.repository?.label?.id {
            return id
        }
        let created = try await client.send(
            "POST",
            "repos/\(repository)/labels",
            body: label,
            as: CreatedLabel.self
        )
        return created.nodeID
    }

    private static let labelQuery = """
        query($owner: String!, $name: String!, $label: String!) {
          repository(owner: $owner, name: $name) { label(name: $label) { id } }
        }
        """

    private static let addCommentMutation = """
        mutation($discussion: ID!, $body: String!) {
          addDiscussionComment(input: { discussionId: $discussion, body: $body }) { comment { id } }
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

private struct AddCommentData: Decodable {
    struct Payload: Decodable {
        let comment: LabelNodeID?
    }

    let addDiscussionComment: Payload?
}

private struct ViewerData: Decodable {
    struct Viewer: Decodable {
        let login: String
    }

    let viewer: Viewer
}
