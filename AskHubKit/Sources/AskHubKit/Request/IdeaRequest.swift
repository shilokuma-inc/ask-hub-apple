import Foundation

/// アプリから出す新機能の依頼（`idea-request` の Issue。Discussion #1 の Q12）
public struct IdeaRequest: Sendable, Equatable {
    /// `owner/repo`
    public var repository: String
    /// 1 行の要約。Issue のタイトルは `【依頼】<要約>`
    public var summary: String
    /// 依頼文（Issue の本文）
    public var body: String

    public init(repository: String, summary: String, body: String) {
        self.repository = repository
        self.summary = summary
        self.body = body
    }

    /// Issue のタイトル
    public var title: String {
        "【依頼】" + summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 送ってよい形か。リポジトリを選び、要約は 1 行で空でなく、依頼文が空でないこと
    public var isValid: Bool {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // 既定の split は空の要素を省くので、"o//r" や "/o/r" も 2 要素に見えてしまう
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !summary.isEmpty
            && !summary.contains(where: \.isNewline)
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 作った依頼の Issue
public struct CreatedIssue: Sendable, Equatable, Decodable {
    public let number: Int
    public let htmlURL: URL

    public init(number: Int, htmlURL: URL) {
        self.number = number
        self.htmlURL = htmlURL
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
    }
}

/// 依頼を出せないときのエラー
public enum IdeaRequestError: Error, Equatable, Sendable {
    /// 入力が揃っていない（リポジトリ・要約・依頼文）
    case invalidRequest
}

/// 依頼の作成先とリポジトリの一覧。テストでは差し替える
public protocol IdeaRequesting: Sendable {
    /// org のリポジトリ。アーカイブ済みを除き、最近 push された順
    func repositories(in org: String) async throws -> [RequestRepository]
    /// `idea-request` ラベル付きの Issue を作る
    func create(_ request: IdeaRequest) async throws -> CreatedIssue
}

/// GitHub の REST API で依頼の Issue を作る
public struct GitHubIdeaRequester: IdeaRequesting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    /// 候補は REST の全件。担当の印は GraphQL の org のリポジトリ一覧から付け足す
    /// （Search API は一覧と件数がずれ、30 回/分の制限もあるので使わない）
    public func repositories(in org: String) async throws -> [RequestRepository] {
        let names = try await client.getAllPages(
            "orgs/\(org)/repos",
            query: [URLQueryItem(name: "type", value: "all"), URLQueryItem(name: "sort", value: "pushed")],
            of: RepositorySummary.self
        )
        .filter { !$0.archived }
        .map(\.fullName)
        // 担当の印は区切りのための付加情報。取れなくても候補は出す（担当の有無は不明として扱う）
        guard let lastSeen = try? await heartbeats(in: org) else {
            return names.map { RequestRepository(fullName: $0, isAssignmentKnown: false) }
        }
        return names.map { RequestRepository(fullName: $0, lastSeen: lastSeen[$0]) }
    }

    /// リポジトリごとの `askhub-orchestrator` の最終確認の時刻。印の無いリポジトリは含めない
    private func heartbeats(in org: String) async throws -> [String: Date] {
        let nodes: [HeartbeatNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.heartbeatQuery,
                variables: [
                    "org": .string(org),
                    "after": after.map(GraphQLVariable.string) ?? .null,
                    "label": .string(OrchestratorHeartbeat.labelName)
                ],
                as: HeartbeatData.self
            )
            guard let connection = data.organization?.repositories else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
        var result: [String: Date] = [:]
        for node in nodes {
            if let date = OrchestratorHeartbeat.lastSeen(in: node.label?.description) {
                result[node.nameWithOwner] = date
            }
        }
        return result
    }

    private static let heartbeatQuery = """
        query($org: String!, $after: String, $label: String!) {
          organization(login: $org) {
            repositories(first: 100, after: $after, isArchived: false) {
              pageInfo { hasNextPage endCursor }
              nodes { nameWithOwner label(name: $label) { description } }
            }
          }
        }
        """

    public func create(_ request: IdeaRequest) async throws -> CreatedIssue {
        guard request.isValid else {
            throw IdeaRequestError.invalidRequest
        }
        return try await client.send(
            "POST",
            "repos/\(request.repository)/issues",
            body: NewIssue(
                title: request.title,
                body: request.body.trimmingCharacters(in: .whitespacesAndNewlines),
                labels: [AskHubLabel.ideaRequest.rawValue]
            ),
            as: CreatedIssue.self
        )
    }
}

private struct RepositorySummary: Decodable {
    let fullName: String
    let archived: Bool

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case archived
    }
}

private struct HeartbeatData: Decodable {
    struct Organization: Decodable {
        let repositories: Connection
    }

    struct Connection: Decodable {
        let pageInfo: GraphQLPageInfo
        let nodes: [HeartbeatNode?]
    }

    let organization: Organization?
}

private struct HeartbeatNode: Decodable {
    struct Label: Decodable {
        let description: String?
    }

    let nameWithOwner: String
    let label: Label?
}

private struct NewIssue: Encodable, Sendable {
    let title: String
    let body: String
    let labels: [String]
}
