import Foundation

extension GitHubPullRequests {
    /// 信用する書き手の、未解決の行コメントのスレッドとレビューの本文を読む
    public func reviewFeedback(number: Int, trusted: TrustedAuthors) async throws(PullRequestError) -> ReviewFeedback {
        let threads = try await unresolvedThreads(number: number, trusted: trusted)
        let reviews = try await reviewBodies(number: number, trusted: trusted)
        return ReviewFeedback(threads: threads, reviews: reviews)
    }

    /// 未解決で、最初のコメント（スレッドの起点）が信用する書き手のスレッド。コメントは信用する書き手のものだけを残す。
    /// 解決済みかは REST では分からないので、GraphQL の `reviewThreads` の `isResolved` で読む
    public func unresolvedThreads(number: Int, trusted: TrustedAuthors) async throws(PullRequestError) -> [ReviewThread] {
        try GitNames.checkNumber(number)
        var threads: [ReviewThread] = []
        var after: String?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= GitHubAPI.maxPages else { throw .malformed("reviewThreads のページが \(GitHubAPI.maxPages) を超えた") }
            let variables = ThreadsVariables(owner: repository.owner, name: repository.name, number: number, after: after)
            let data = try await api.graphQL(ReviewQueries.threads, variables: variables, as: ThreadsData.self)
            guard let connection = data.repository?.pullRequest?.reviewThreads else { throw .notFound }
            for node in connection.nodes.compactMap(\.self) where !node.isResolved {
                guard let root = node.comments.nodes.first.flatMap({ $0 }), root.isTrusted(trusted) else { continue }
                let comments = try await allComments(of: node)
                threads.append(node.model(comments: comments.filter { $0.isTrusted(trusted) }.map { $0.model() }))
            }
            after = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : nil
        } while after != nil
        return threads
    }

    /// 信用する書き手の、本文のあるレビュー（下書き `PENDING` と取り下げ `DISMISSED` は除く）
    public func reviewBodies(number: Int, trusted: TrustedAuthors) async throws(PullRequestError) -> [ReviewBody] {
        try GitNames.checkNumber(number)
        let pages = try await api.pages(
            "pulls/\(number)/reviews",
            query: [URLQueryItem(name: "per_page", value: "100")],
            as: [ReviewPayload].self
        )
        return pages.joined().compactMap { review -> ReviewBody? in
            guard let user = review.user, trusted.contains(restLogin: user.login, type: user.type),
                  !["PENDING", "DISMISSED"].contains(review.state),
                  let body = review.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ReviewBody(
                id: review.id,
                author: user.login,
                state: review.state,
                body: body,
                commitID: review.commitId,
                submittedAt: review.submittedAt.flatMap(GitHubDate.parse),
                url: review.htmlUrl.flatMap(URL.init(string:))
            )
        }
    }

    /// スレッドのコメントを最後まで読む（1 つのスレッドに 100 件を超えるコメントがあれば、続きを node で読む）
    private func allComments(of thread: ThreadNode) async throws(PullRequestError) -> [CommentNode] {
        var comments = thread.comments.nodes.compactMap(\.self)
        var pageInfo = thread.comments.pageInfo
        var pages = 1
        while pageInfo.hasNextPage, let after = pageInfo.endCursor {
            pages += 1
            guard pages <= GitHubAPI.maxPages else { throw .malformed("スレッドのコメントのページが \(GitHubAPI.maxPages) を超えた") }
            let variables = CommentsVariables(id: thread.id, after: after)
            let data = try await api.graphQL(ReviewQueries.moreComments, variables: variables, as: MoreCommentsData.self)
            guard let connection = data.node?.comments else { throw .notFound }
            comments += connection.nodes.compactMap(\.self)
            pageInfo = connection.pageInfo
        }
        return comments
    }
}

// MARK: - GraphQL の問い合わせ

enum ReviewQueries {
    static let commentPage = """
    fragment CommentPage on PullRequestReviewCommentConnection {
      pageInfo { hasNextPage endCursor }
      nodes { databaseId body url createdAt author { __typename login } }
    }
    """

    static let threads = """
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id isResolved isOutdated path line comments(first: 100) { ...CommentPage } }
          }
        }
      }
    }
    """ + "\n" + commentPage

    static let moreComments = """
    query($id: ID!, $after: String) {
      node(id: $id) {
        ... on PullRequestReviewThread { comments(first: 100, after: $after) { ...CommentPage } }
      }
    }
    """ + "\n" + commentPage
}

private struct ThreadsVariables: Encodable, Sendable {
    let owner: String
    let name: String
    let number: Int
    let after: String?
}

private struct CommentsVariables: Encodable, Sendable {
    let id: String
    let after: String
}

// MARK: - 応答の形

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct ThreadsData: Decodable {
    struct Repository: Decodable {
        let pullRequest: PullRequestThreads?
    }

    let repository: Repository?
}

private struct PullRequestThreads: Decodable {
    struct Threads: Decodable {
        let pageInfo: PageInfo
        let nodes: [ThreadNode?]
    }

    let reviewThreads: Threads
}

private struct MoreCommentsData: Decodable {
    struct Node: Decodable {
        /// スレッドでない node なら無い
        let comments: CommentConnection?
    }

    let node: Node?
}

struct CommentConnection: Decodable {
    let pageInfo: PageInfo
    let nodes: [CommentNode?]
}

struct ThreadNode: Decodable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String?
    let line: Int?
    let comments: CommentConnection

    func model(comments: [ReviewComment]) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, isOutdated: isOutdated, comments: comments)
    }
}

/// GraphQL の `author`
struct GraphQLAuthor: Decodable {
    let typename: String
    let login: String

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
    }
}

struct CommentNode: Decodable {
    let databaseId: Int?
    let body: String
    let url: String?
    let createdAt: String?
    /// 消えたアカウントなら null
    let author: GraphQLAuthor?

    func isTrusted(_ trusted: TrustedAuthors) -> Bool {
        guard let author else { return false }
        return trusted.contains(graphQLLogin: author.login, typename: author.typename)
    }

    /// author は REST の形（bot は `[bot]` 付き）にそろえる
    func model() -> ReviewComment {
        let login = author.map { $0.typename == "Bot" ? "\($0.login)[bot]" : $0.login } ?? ""
        return ReviewComment(
            id: databaseId,
            author: login,
            body: body,
            url: url.flatMap(URL.init(string:)),
            createdAt: createdAt.flatMap(GitHubDate.parse)
        )
    }
}

private struct ReviewPayload: Decodable {
    struct User: Decodable {
        let login: String
        let type: String?
    }

    let id: Int
    /// 消えたアカウントなら null
    let user: User?
    let body: String?
    let state: String
    let commitId: String?
    let submittedAt: String?
    let htmlUrl: String?
}
