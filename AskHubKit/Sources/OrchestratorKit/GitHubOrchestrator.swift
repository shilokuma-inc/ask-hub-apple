import AskHubKit
import Foundation

/// GitHub の GraphQL API でオーケストレーターの操作を行う
public struct GitHubOrchestrator: OrchestratorGitHub {
    let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func readyForLoopDiscussions(orgs: [String]) async throws -> [ReadyDiscussion] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let label = AskHubLabel.readyForLoop.rawValue
        // 担当リポジトリごとではなく organization 全体を 1 回で検索する（Search API のレート制限のため）。
        // 検索結果は 1,000 件までなので、closed の Discussion で上限を埋めないよう検索の段階で open に絞る
        let query = "\(scope) label:\(label) is:open"
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
                readyLabelID: labelID,
                isManualLoop: node.labelID(named: AskHubLabel.manualLoop.rawValue) != nil
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

    public func addReadyLabel(to subject: InboxSubject) async throws {
        let parts = subject.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        // Discussion のラベルは REST で付けられないため、リポジトリのラベルの node id を引いて GraphQL で付ける
        let data = try await client.graphQL(
            Self.labelQuery,
            variables: [
                "owner": .string(parts[0]),
                "name": .string(parts[1]),
                "label": .string(AskHubLabel.readyForLoop.rawValue)
            ],
            as: LabelData.self
        )
        guard let labelID = data.repository?.label?.id else {
            // ラベルが無いと付けられない（ralph-setup.sh が作る）。失敗として返し、needs-answer を残す
            throw GitHubError.invalidResponse
        }
        let added = try await client.graphQL(
            Self.addLabelMutation,
            variables: ["labelable": .string(subject.nodeID), "labels": .strings([labelID])],
            as: AddLabelsData.self
        )
        // errors が無くても payload が null なら付いていない。成功扱いにすると needs-answer だけが外れ、
        // この Discussion は回答待ちの検索にもループの起動の検索にも出なくなる
        guard added.addLabelsToLabelable != nil else {
            throw GitHubError.invalidResponse
        }
    }

    public func existingPullRequest(in repository: String, head branch: String) async throws -> ExistingPullRequest? {
        let owner = try Self.owner(of: repository)
        // 最終 PR と同じ統合先（既定ブランチ）への PR だけを見る。別の base への PR では最終 PR の代わりにならない
        let base = try await defaultBranch(of: repository)
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [
                URLQueryItem(name: "head", value: "\(owner):\(branch)"),
                URLQueryItem(name: "base", value: base),
                URLQueryItem(name: "state", value: "all")
            ],
            of: PullRequestSummary.self
        )
        // open なものがあればそれを、無ければマージ済みのもの、それも無ければ最初のもの（閉じた PR）を返す
        let pull = pulls.first { $0.state == "open" } ?? pulls.first { $0.mergedAt != nil } ?? pulls.first
        return pull.map { ExistingPullRequest(number: $0.number, isOpen: $0.state == "open", body: $0.body, isMerged: $0.mergedAt != nil) }
    }

    public func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int {
        let base = try await defaultBranch(of: repository)
        let pull = try await client.send(
            "POST",
            "repos/\(repository)/pulls",
            body: NewPullRequest(
                title: Self.epicFinalTitle(branch: branch, base: base),
                head: branch,
                base: base,
                body: body + Self.epicFinalFooter
            ),
            as: PullRequestSummary.self
        )
        return pull.number
    }

    public func updatePullRequestBody(in repository: String, number: Int, body: String) async throws {
        _ = try await client.send("PATCH", "repos/\(repository)/pulls/\(number)", body: ["body": body], as: PullRequestSummary.self)
    }

    public func addEpicFinalLabel(in repository: String, number: Int) async throws {
        // PR のラベルは Issue の API で付ける。既に付いているラベルを足しても失敗しない
        _ = try await client.send(
            "POST",
            "repos/\(repository)/issues/\(number)/labels",
            body: ["labels": [AskHubLabel.epicFinal.rawValue]],
            as: [LabelName].self
        )
    }

    /// 統合先は Q13 の develop。リポジトリの既定ブランチとして読む
    private func defaultBranch(of repository: String) async throws -> String {
        try await client.get("repos/\(repository)", as: RepositoryInfo.self).defaultBranch
    }

    public func ideaRequests(orgs: [String]) async throws -> [IdeaRequestIssue] {
        try await requestIssues(labeled: .ideaRequest, orgs: orgs)
    }

    /// organization 全体の、`label` が付いた open な Issue（アプリから出した依頼）
    func requestIssues(labeled label: AskHubLabel, orgs: [String]) async throws -> [IdeaRequestIssue] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let query = "\(scope) is:issue is:open label:\(label.rawValue)"
        let nodes: [IdeaIssueNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.ideaSearchQuery,
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
                as: IdeaSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let repository = node.repository?.nameWithOwner else {
                return nil
            }
            return IdeaRequestIssue(
                nodeID: id,
                repository: repository,
                number: number,
                title: title,
                body: node.body ?? "",
                url: url,
                author: node.author?.login,
                editor: node.editor?.login
            )
        }
    }

    public func comment(on issue: IdeaRequestIssue, body: String) async throws {
        _ = try await client.send(
            "POST",
            "repos/\(issue.repository)/issues/\(issue.number)/comments",
            body: ["body": body],
            as: CommentID.self
        )
    }

    public func close(_ issue: IdeaRequestIssue) async throws {
        _ = try await client.send(
            "PATCH",
            "repos/\(issue.repository)/issues/\(issue.number)",
            body: ["state": "closed", "state_reason": "completed"],
            as: PullRequestSummary.self
        )
    }

    private static let ideaSearchQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: ISSUE, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Issue { id number title body url author { login } editor { login } repository { nameWithOwner } }
            }
          }
        }
        """

    public func updateHeartbeat(in repository: String, description: String) async throws {
        do {
            _ = try await client.send(
                "PATCH",
                "repos/\(repository)/labels/\(OrchestratorHeartbeat.labelName)",
                body: ["description": description],
                as: LabelName.self
            )
        } catch GitHubError.http(status: 404, _) {
            // まだラベルが無い
            _ = try await client.send(
                "POST",
                "repos/\(repository)/labels",
                body: ["name": OrchestratorHeartbeat.labelName, "color": "c5def5", "description": description],
                as: LabelName.self
            )
        }
    }

    public func decisionLogs(in repository: String) async throws -> [DecisionLogIssue] {
        let issues = try await client.getAllPages(
            "repos/\(repository)/issues",
            query: [
                URLQueryItem(name: "labels", value: AskHubLabel.decisionLog.rawValue),
                URLQueryItem(name: "state", value: "open")
            ],
            of: IssueSummary.self
        )
        // Issue の API は PR も返すので除く
        return issues.filter { $0.pullRequest == nil }.map {
            DecisionLogIssue(repository: repository, number: $0.number, title: $0.title, body: $0.body ?? "")
        }
    }

    public func comments(in repository: String, issue number: Int) async throws -> [IssueComment] {
        try await client.getAllPages("repos/\(repository)/issues/\(number)/comments", of: IssueCommentSummary.self).map {
            IssueComment(id: $0.id, author: $0.user?.login, body: $0.body ?? "")
        }
    }

    public func comment(on issue: DecisionLogIssue, body: String) async throws {
        _ = try await client.send(
            "POST",
            "repos/\(issue.repository)/issues/\(issue.number)/comments",
            body: ["body": body],
            as: CommentID.self
        )
    }

    public func close(_ issue: DecisionLogIssue) async throws {
        _ = try await client.send(
            "PATCH",
            "repos/\(issue.repository)/issues/\(issue.number)",
            body: ["state": "closed", "state_reason": "completed"],
            as: PullRequestSummary.self
        )
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

    private static let addLabelMutation = """
        mutation($labelable: ID!, $labels: [ID!]!) {
          addLabelsToLabelable(input: { labelableId: $labelable, labelIds: $labels }) { clientMutationId }
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

private struct AddLabelsData: Decodable {
    struct Payload: Decodable {
        let clientMutationId: String?
    }

    let addLabelsToLabelable: Payload?
}

private struct PullRequestSummary: Decodable {
    let number: Int
    /// `open` / `closed`（マージ済みも `closed`）
    let state: String
    let body: String?
    /// マージした時刻。マージされていなければ `nil`（Issue の API の応答にも使うので、そこでは常に `nil`）
    let mergedAt: String?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case body
        case mergedAt = "merged_at"
    }
}

private struct IssueSummary: Decodable {
    let number: Int
    let title: String
    let body: String?
    /// PR のときだけある
    let pullRequest: PullRequestLink?

    struct PullRequestLink: Decodable {}

    private enum CodingKeys: String, CodingKey {
        case number
        case title
        case body
        case pullRequest = "pull_request"
    }
}

private struct IssueCommentSummary: Decodable {
    let id: Int
    let user: User?
    let body: String?

    struct User: Decodable {
        let login: String
    }
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

private struct IdeaSearchData: Decodable {
    let search: Connection<IdeaIssueNode>
}

/// 検索結果の依頼 Issue
private struct IdeaIssueNode: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let body: String?
    let url: URL?
    let author: SearchNode.Author?
    let editor: SearchNode.Author?
    let repository: SearchNode.Repository?
}

private struct CommentID: Decodable {
    let id: Int
}
