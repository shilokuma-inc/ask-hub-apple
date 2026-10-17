import Foundation

/// 最終 PR の CodeRabbit の未解決のレビュースレッドを取得する。テストでは差し替える
public protocol CodeRabbitThreadsFetching: Sendable {
    /// 未解決（`isResolved == false`）で、最初のコメントを CodeRabbit が書いたスレッドを、GitHub の並び順で返す
    func unresolvedCodeRabbitThreads(of pullRequest: EpicPullRequest) async throws -> [CodeRabbitReviewThread]
}

/// GitHub の GraphQL API（`reviewThreads`）で CodeRabbit の未解決のスレッドを取得する。
/// スレッドもスレッドの中のコメントも、ページングを最後まで追う。レート制限は `GitHubClient` が待って再試行する
public struct GitHubCodeRabbitThreads: CodeRabbitThreadsFetching {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func unresolvedCodeRabbitThreads(of pullRequest: EpicPullRequest) async throws -> [CodeRabbitReviewThread] {
        let threads: [ThreadNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.reviewThreadsQuery,
                variables: ["id": .string(pullRequest.id), "after": after.map(GraphQLVariable.string) ?? .null],
                as: NodeData<PullRequestNode>.self
            )
            guard let connection = data.node?.reviewThreads else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
        var result: [CodeRabbitReviewThread] = []
        for thread in threads where !thread.isResolved {
            // 最初のコメントで CodeRabbit の指摘かを決める。そうでなければ続きのコメントは読まない
            guard let first = thread.comments.nodes.first.flatMap(\.self),
                  CodeRabbitReviewThread.isCodeRabbit(first.author?.login) else {
                continue
            }
            var comments = thread.comments.nodes.compactMap(\.self)
            if thread.comments.pageInfo.hasNextPage {
                comments += try await remainingComments(threadID: thread.id, after: thread.comments.pageInfo.endCursor)
            }
            let converted = comments.compactMap(\.comment)
            guard let finding = converted.first, finding.id == first.databaseId else {
                continue
            }
            result.append(CodeRabbitReviewThread(
                id: thread.id,
                path: thread.path,
                line: thread.line,
                isOutdated: thread.isOutdated,
                finding: finding,
                replies: Array(converted.dropFirst())
            ))
        }
        return result
    }

    /// 2 ページ目以降のスレッドのコメント
    private func remainingComments(threadID: String, after firstCursor: String?) async throws -> [CommentNode] {
        guard let firstCursor else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.threadCommentsQuery,
                variables: ["id": .string(threadID), "after": .string(after ?? firstCursor)],
                as: NodeData<ThreadCommentsNode>.self
            )
            guard let connection = data.node?.comments else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (connection.nodes.compactMap(\.self), connection.pageInfo)
        }
    }

    private static let commentFields = "databaseId url createdAt body author { login }"

    private static let reviewThreadsQuery = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequest {
              reviewThreads(first: 50, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved isOutdated path line
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
}

// MARK: - レスポンスの形

private struct NodeData<Node: Decodable>: Decodable {
    /// 削除済みなどで見つからない場合は `null`
    let node: Node?
}

private struct Connection<Node: Decodable>: Decodable {
    let pageInfo: GraphQLPageInfo
    /// GitHub の GraphQL は要素が `null` になりうる
    let nodes: [Node?]
}

private struct PullRequestNode: Decodable {
    let reviewThreads: Connection<ThreadNode>?
}

private struct ThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String
    let line: Int?
    let comments: Connection<CommentNode>
}

private struct ThreadCommentsNode: Decodable {
    let comments: Connection<CommentNode>?
}

private struct CommentNode: Decodable {
    struct Author: Decodable {
        let login: String
    }

    let databaseId: Int?
    let url: URL
    let createdAt: Date
    let body: String
    let author: Author?

    /// `databaseId` が無いコメントは指示で指せないので落とす
    var comment: CodeRabbitReviewThread.Comment? {
        databaseId.map { CodeRabbitReviewThread.Comment(id: $0, author: author?.login, body: body, url: url, createdAt: createdAt) }
    }
}
