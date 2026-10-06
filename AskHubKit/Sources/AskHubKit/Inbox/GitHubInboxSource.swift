import Foundation

/// GitHub の GraphQL API から受信箱を取得する。
///
/// 検索・コメント・返信のいずれも、ページングを最後まで追う
public struct GitHubInboxSource: InboxSource {
    let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let label = AskHubLabel.needsAnswer.rawValue
        // 検索結果は 1,000 件までなので、closed で上限を埋めないよう検索の段階で open に絞る（取得後の `closed` でも除く）
        let discussions = try await search(
            query: "\(scope) label:\(label) is:open",
            type: "DISCUSSION",
            kind: .discussion
        )
        let pullRequests = try await search(
            query: "\(scope) label:\(label) is:pr is:open",
            type: "ISSUE",
            kind: .pullRequest
        )
        return discussions + pullRequests
    }

    public func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        switch subject.kind {
        case .discussion:
            try await discussionThreads(id: subject.nodeID)

        case .pullRequest:
            try await reviewThreads(id: subject.nodeID)
        }
    }

    public func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        // ラベルをカンマで並べると OR で検索できるので、1 回の検索で済ませる
        let labels = InboxIssue.Kind.labels.map(\.rawValue).joined(separator: ",")
        let nodes: [IssueSearchNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.issueSearchQuery,
                variables: [
                    "query": .string("\(scope) is:issue is:open label:\(labels)"),
                    "after": after.map(GraphQLVariable.string) ?? .null
                ],
                as: IssueSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let updatedAt = node.updatedAt, let repository = node.repository?.nameWithOwner,
                  let kind = InboxIssue.Kind(labelNames: node.labels?.nodes.compactMap(\.self).map(\.name) ?? []) else {
                return nil
            }
            return InboxIssue(
                id: id,
                kind: kind,
                repository: repository,
                number: number,
                title: title,
                url: url,
                author: node.author?.login,
                updatedAt: updatedAt
            )
        }
    }

    private static let issueSearchQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: ISSUE, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Issue {
                id number title url updatedAt
                author { login }
                repository { nameWithOwner }
                labels(first: 100) { nodes { name } }
              }
            }
          }
        }
        """

    public func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let query = "\(scope) label:\(AskHubLabel.readyForLoop.rawValue) is:open"
        let nodes: [WaitingNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.waitingQuery,
                variables: [
                    "query": .string(query),
                    "after": after.map(GraphQLVariable.string) ?? .null,
                    "label": .string(OrchestratorHeartbeat.labelName)
                ],
                as: WaitingSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let repository = node.repository, node.closed != true else {
                return nil
            }
            let subject = InboxSubject(
                kind: .discussion,
                nodeID: id,
                repository: repository.nameWithOwner,
                number: number,
                title: title,
                url: url
            )
            return WaitingDiscussion(
                subject: subject,
                lastSeen: OrchestratorHeartbeat.lastSeen(in: repository.label?.description),
                author: node.author?.login,
                usageLimitedUntil: OrchestratorHeartbeat.usageLimitedUntil(in: repository.label?.description)
            )
        }
    }

    // MARK: - 検索

    private func search(query: String, type: String, kind: InboxSubject.Kind) async throws -> [InboxSubject] {
        let nodes: [SearchNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.searchQuery(type: type),
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
                as: SearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            // 検索の型に合わないノードは `{}` で返るので、必要な値が揃ったものだけを使う
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let repository = node.repository?.nameWithOwner, node.closed != true else {
                return nil
            }
            return InboxSubject(kind: kind, nodeID: id, repository: repository, number: number, title: title, url: url)
        }
    }

    private static func searchQuery(type: String) -> String {
        """
        query($query: String!, $after: String) {
          search(query: $query, type: \(type), first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Discussion { id number title url closed repository { nameWithOwner } }
              ... on PullRequest { id number title url closed repository { nameWithOwner } }
            }
          }
        }
        """
    }

    // MARK: - Discussion

    private func discussionThreads(id: String) async throws -> [QuestionThread] {
        let comments: [DiscussionCommentNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.discussionCommentsQuery,
                variables: ["id": .string(id), "after": after.map(GraphQLVariable.string) ?? .null],
                as: NodeData<DiscussionNode>.self
            )
            guard let connection = data.node?.comments else {
                // 取得の途中で削除された場合など
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
        var threads: [QuestionThread] = []
        for comment in comments {
            var replyAuthors = comment.replies.nodes.compactMap(\.self).map(\.author?.login)
            if comment.replies.pageInfo.hasNextPage {
                replyAuthors += try await remainingReplyAuthors(
                    commentID: comment.comment.id,
                    after: comment.replies.pageInfo.endCursor
                )
            }
            threads.append(QuestionThread(comment: comment.comment.inboxComment, replyAuthors: replyAuthors))
        }
        return threads
    }

    /// 2 ページ目以降の返信の author
    private func remainingReplyAuthors(commentID: String, after firstCursor: String?) async throws -> [String?] {
        guard let firstCursor else {
            throw GitHubError.invalidResponse
        }
        let replies: [ReplyNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.discussionRepliesQuery,
                variables: ["id": .string(commentID), "after": .string(after ?? firstCursor)],
                as: NodeData<DiscussionCommentRepliesNode>.self
            )
            guard let connection = data.node?.replies else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
        return replies.map(\.author?.login)
    }

    private static let discussionCommentsQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on Discussion {
              comments(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  \(commentFields)
                  replies(first: 50) {
                    pageInfo { hasNextPage endCursor }
                    nodes { author { login } }
                  }
                }
              }
            }
          }
        }
        """

    private static let discussionRepliesQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on DiscussionComment {
              replies(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { author { login } }
              }
            }
          }
        }
        """

    // MARK: - PR

    private func reviewThreads(id: String) async throws -> [QuestionThread] {
        let threads: [PullRequestNode.Thread] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.reviewThreadsQuery,
                variables: ["id": .string(id), "after": after.map(GraphQLVariable.string) ?? .null],
                as: NodeData<PullRequestNode>.self
            )
            guard let connection = data.node?.reviewThreads else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
        var result: [QuestionThread] = []
        for thread in threads {
            var comments = thread.comments.nodes.compactMap(\.self)
            if thread.comments.pageInfo.hasNextPage {
                comments += try await remainingThreadComments(
                    threadID: thread.id,
                    after: thread.comments.pageInfo.endCursor
                )
            }
            // スレッドの最初のコメントが質問、2 件目以降がその返信（`in_reply_to`）にあたる
            guard let first = comments.first else {
                continue
            }
            result.append(QuestionThread(
                comment: first.inboxComment,
                replyAuthors: comments.dropFirst().map(\.author?.login)
            ))
        }
        return result
    }

    /// 2 ページ目以降のレビュースレッドのコメント
    private func remainingThreadComments(threadID: String, after firstCursor: String?) async throws -> [CommentNode] {
        guard let firstCursor else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.threadCommentsQuery,
                variables: ["id": .string(threadID), "after": .string(after ?? firstCursor)],
                as: NodeData<ReviewThreadCommentsNode>.self
            )
            guard let connection = data.node?.comments else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
    }

    private static let reviewThreadsQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequest {
              reviewThreads(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id
                  comments(first: 50) {
                    pageInfo { hasNextPage endCursor }
                    nodes { \(commentFields) }
                  }
                }
              }
            }
          }
        }
        """

    private static let threadCommentsQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequestReviewThread {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { \(commentFields) }
              }
            }
          }
        }
        """

    private static let commentFields = "id databaseId url createdAt body author { login }"
}

// MARK: - レスポンスの形

private struct IssueSearchData: Decodable {
    let search: Connection<IssueSearchNode>
}

/// 検索結果の Issue
private struct IssueSearchNode: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Label: Decodable {
        let name: String
    }

    struct Labels: Decodable {
        let nodes: [Label?]
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let updatedAt: Date?
    let author: Author?
    let repository: Repository?
    let labels: Labels?
}

private struct Connection<Node: Decodable>: Decodable {
    let pageInfo: GraphQLPageInfo
    /// GitHub の GraphQL は要素が `null` になりうる
    let nodes: [Node?]
}

private struct Author: Decodable {
    let login: String
}

private struct SearchData: Decodable {
    let search: Connection<SearchNode>
}

/// 検索結果の Discussion / PR
private struct SearchNode: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let closed: Bool?
    let repository: Repository?
}

private struct NodeData<Node: Decodable>: Decodable {
    /// 削除済みなどで見つからない場合は `null`
    let node: Node?
}

private struct CommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let url: URL
    let createdAt: Date
    let body: String
    let author: Author?

    var inboxComment: InboxComment {
        InboxComment(nodeID: id, databaseID: databaseId, author: author?.login, body: body, url: url, createdAt: createdAt)
    }
}

private struct ReplyNode: Decodable {
    let author: Author?
}

private struct DiscussionNode: Decodable {
    /// `... on Discussion` に合わないノードでは無い
    let comments: Connection<DiscussionCommentNode>?
}

/// Discussion のコメントと、最初のページの返信
private struct DiscussionCommentNode: Decodable {
    private enum CodingKeys: String, CodingKey {
        case replies
    }

    let comment: CommentNode
    let replies: Connection<ReplyNode>

    init(from decoder: any Decoder) throws {
        comment = try CommentNode(from: decoder)
        replies = try decoder.container(keyedBy: CodingKeys.self).decode(Connection<ReplyNode>.self, forKey: .replies)
    }
}

private struct DiscussionCommentRepliesNode: Decodable {
    let replies: Connection<ReplyNode>?
}

private struct PullRequestNode: Decodable {
    struct Thread: Decodable {
        let id: String
        let comments: Connection<CommentNode>
    }

    let reviewThreads: Connection<Thread>?
}

private struct ReviewThreadCommentsNode: Decodable {
    let comments: Connection<CommentNode>?
}

private struct WaitingSearchData: Decodable {
    let search: Connection<WaitingNode>
}

/// ループの開始を待っている Discussion
private struct WaitingNode: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
        let label: HeartbeatLabel?
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let closed: Bool?
    let author: Author?
    let repository: Repository?
}

private struct HeartbeatLabel: Decodable {
    let description: String?
}
