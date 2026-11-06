import AskHubProtocol
import AskHubStateStore
import Foundation

/// GitHub の GraphQL API で、対象のリポジトリの Discussion を読み書きする。
///
/// - トークンは要求のたびに Keychain などから読む。値はログ・URL・エラーに出さない
/// - コメントの作成・更新は内容を作る要求なので、状態リポジトリと同じ書き込みの予算に数える（同じアカウントの上限を分け合うため）
/// - 一覧はページングを最後まで追う。上限（403・429・`RATE_LIMITED`）は `StateStoreError.rateLimited` にする
public struct GitHubDiscussions: DiscussionAPI {
    private let endpoint: URL
    private let transport: any HTTPTransport
    private let token: @Sendable () async throws -> String
    private let budget: WriteBudget?
    private let now: @Sendable () -> Date

    public init(
        endpoint: URL = URL(string: "https://api.github.com/graphql")!,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        budget: WriteBudget?,
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable () async throws -> String
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.budget = budget
        self.now = now
        self.token = token
    }

    public func repository(_ repo: RepositoryFullName) async throws(DiscussionError) -> DiscussionRepository {
        let response = try await send(DiscussionQueries.repository, variables: Self.variables(of: repo), as: RepositoryData.self)
        guard let repository = try response.requireData().repository else { throw .malformed("リポジトリ \(repo) が見えない") }
        return DiscussionRepository(
            id: repository.id,
            discussionsEnabled: repository.hasDiscussionsEnabled,
            categories: repository.discussionCategories.nodes.compactMap { $0.map { .init(id: $0.id, name: $0.name) } }
        )
    }

    public func discussion(_ repo: RepositoryFullName, number: Int) async throws(DiscussionError) -> DiscussionThread? {
        var thread: DiscussionThread?
        var cursor: String?
        repeat {
            var variables = Self.variables(of: repo)
            variables["number"] = .integer(Int64(number))
            if let cursor { variables["after"] = .string(cursor) }
            let response = try await send(DiscussionQueries.discussion, variables: variables, as: DiscussionData.self)
            // 無い番号は、data の discussion が null で、errors に NOT_FOUND が入る
            guard let found = try response.allowingNotFound().repository?.discussion else { return nil }
            var comments: [DiscussionThread.Comment] = []
            for node in found.comments.nodes.compactMap(\.self) {
                comments.append(.init(post: node.post, replies: try await replies(of: node)))
            }
            if thread == nil {
                thread = DiscussionThread(
                    id: found.id, number: found.number, title: found.title, body: found.body, viewerDidAuthor: found.viewerDidAuthor
                )
            }
            thread?.comments += comments
            cursor = try Self.next(found.comments.pageInfo, after: cursor)
        } while cursor != nil
        return thread
    }

    public func discussions(_ repo: RepositoryFullName, createdSince since: Date) async throws(DiscussionError) -> [DiscussionSummary] {
        var found: [DiscussionSummary] = []
        var cursor: String?
        repeat {
            var variables = Self.variables(of: repo)
            if let cursor { variables["after"] = .string(cursor) }
            let response = try await send(DiscussionQueries.discussions, variables: variables, as: DiscussionsData.self)
            guard let page = try response.requireData().repository?.discussions else { throw .malformed("リポジトリ \(repo) が見えない") }
            for node in page.nodes.compactMap(\.self) {
                guard let createdAt = try? Date(node.createdAt, strategy: .iso8601) else {
                    throw .malformed("Discussion の作成の時刻を読めない")
                }
                // 新しい順なので、`since` より前のものが出たら、それより後のページは読まない
                guard createdAt >= since else { return found }
                found.append(
                    .init(id: node.id, number: node.number, body: node.body, viewerDidAuthor: node.viewerDidAuthor, createdAt: createdAt)
                )
            }
            cursor = try Self.next(page.pageInfo, after: cursor)
        } while cursor != nil
        return found
    }

    public func missing(_ ids: [String]) async throws(DiscussionError) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let response = try await send(DiscussionQueries.nodes, variables: ["ids": .array(ids.map(JSONValue.string))], as: NodesData.self)
        // 無い id は、nodes の同じ位置が null で、errors に NOT_FOUND が入る
        let nodes = try response.allowingNotFound().nodes
        guard nodes.count == ids.count else { throw .malformed("nodes の数が、問い合わせた id の数と合わない") }
        return Set(zip(ids, nodes).filter { $0.1 == nil }.map(\.0))
    }

    public func createDiscussion(
        repository: String,
        category: String,
        title: String,
        body: String
    ) async throws(DiscussionError) -> DiscussionSummary {
        let variables: [String: JSONValue] = [
            "repository": .string(repository), "category": .string(category), "title": .string(title), "body": .string(body)
        ]
        let response = try await mutate(DiscussionQueries.createDiscussion, variables: variables, as: CreateDiscussionData.self)
        // 権限が足りないなどでは、payload が null になる
        guard let created = try response.requireData().createDiscussion?.discussion else { throw .malformed("作った Discussion が返らない") }
        return DiscussionSummary(id: created.id, number: created.number, body: body, viewerDidAuthor: true, createdAt: now())
    }

    public func updateDiscussion(_ id: String, title: String, body: String) async throws(DiscussionError) {
        let variables: [String: JSONValue] = ["id": .string(id), "title": .string(title), "body": .string(body)]
        let response = try await mutate(DiscussionQueries.updateDiscussion, variables: variables, as: UpdateDiscussionData.self)
        guard try response.requireData().updateDiscussion?.discussion != nil else { throw .malformed("直した Discussion が返らない") }
    }

    public func addComment(to discussion: String, replyingTo parent: String?, body: String) async throws(DiscussionError) -> String {
        let variables: [String: JSONValue] = [
            "discussion": .string(discussion), "replyTo": parent.map(JSONValue.string) ?? .null, "body": .string(body)
        ]
        let response = try await mutate(DiscussionQueries.addComment, variables: variables, as: AddCommentData.self)
        guard let comment = try response.requireData().addDiscussionComment?.comment else { throw .malformed("足したコメントが返らない") }
        return comment.id
    }

    public func updateComment(_ id: String, body: String) async throws(DiscussionError) {
        let variables: [String: JSONValue] = ["id": .string(id), "body": .string(body)]
        let response = try await mutate(DiscussionQueries.updateComment, variables: variables, as: UpdateCommentData.self)
        guard try response.requireData().updateDiscussionComment?.comment != nil else { throw .malformed("直したコメントが返らない") }
    }

    private static func variables(of repo: RepositoryFullName) -> [String: JSONValue] {
        ["owner": .string(repo.owner), "name": .string(repo.name)]
    }

    // MARK: - ページング

    /// コメントへの返信。最初の 100 件で足りなければ、続きを読む
    private func replies(of comment: CommentNode) async throws(DiscussionError) -> [DiscussionPost] {
        var posts = comment.replies.nodes.compactMap { $0?.post }
        var cursor = try Self.next(comment.replies.pageInfo, after: nil)
        while let after = cursor {
            let variables: [String: JSONValue] = ["id": .string(comment.id), "after": .string(after)]
            let response = try await send(DiscussionQueries.replies, variables: variables, as: RepliesData.self)
            guard let page = try response.requireData().node?.replies else { throw .malformed("返信を読めない") }
            posts += page.nodes.compactMap { $0?.post }
            cursor = try Self.next(page.pageInfo, after: after)
        }
        return posts
    }

    /// 次のページのカーソル。最後のページなら nil。続きがあるのにカーソルが進まなければ、止まらないので失敗にする
    private static func next(_ page: PageInfo, after cursor: String?) throws(DiscussionError) -> String? {
        guard page.hasNextPage else { return nil }
        guard let next = page.endCursor, next != cursor else { throw .malformed("ページのカーソルが進まない") }
        return next
    }

    // MARK: - 要求

    /// 内容を作る要求。書き込みの予算に数えてから送る
    private func mutate<Data: Decodable>(
        _ query: String,
        variables: [String: JSONValue],
        as type: Data.Type
    ) async throws(DiscussionError) -> GraphQLResponse<Data> {
        do {
            try await budget?.reserve(now: now())
        } catch {
            throw .http(error)
        }
        return try await send(query, variables: variables, as: type)
    }

    private func send<Data: Decodable>(
        _ query: String,
        variables: [String: JSONValue],
        as type: Data.Type
    ) async throws(DiscussionError) -> GraphQLResponse<Data> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        } catch {
            throw .malformed("要求の本文を作れない")
        }
        do {
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        } catch is CancellationError {
            throw .http(.cancelled)
        } catch {
            throw .http(.tokenUnavailable)
        }
        let (body, response) = try await transport(request)
        guard response.statusCode == 200 else { throw .http(StateStoreError.classify(response, body: body, now: now())) }
        guard let decoded = try? JSONDecoder().decode(GraphQLResponse<Data>.self, from: body) else { throw .malformed("応答を読めない") }
        // 一次の上限は、200 で errors の type が RATE_LIMITED になる
        if decoded.errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
            let wait = reset.map { Int(max($0 - now().timeIntervalSince1970, 0).rounded(.up)) + 1 } ?? 60
            throw .http(.rateLimited(retryAfter: .seconds(wait)))
        }
        return decoded
    }

    private func transport(_ request: URLRequest) async throws(DiscussionError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw .http(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            throw .http(.cancelled)
        } catch let error as URLError {
            throw .http(.transport("URLError \(error.code.rawValue)"))
        } catch {
            throw .http(.transport(String(describing: type(of: error))))
        }
    }
}

// MARK: - 応答の形

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: JSONValue]
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    struct Failure: Decodable {
        let type: String?
        let message: String
    }

    let data: Payload?
    let errors: [Failure]

    enum CodingKeys: String, CodingKey {
        case data, errors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(Payload.self, forKey: .data)
        errors = try container.decodeIfPresent([Failure].self, forKey: .errors) ?? []
    }

    /// errors が無いときの data
    func requireData() throws(DiscussionError) -> Payload {
        if let failure = errors.first { throw .graphQL(type: failure.type, message: failure.message) }
        guard let data else { throw .malformed("data が無い") }
        return data
    }

    /// 無いもの（NOT_FOUND）だけの errors は、無いものとして data を使う
    func allowingNotFound() throws(DiscussionError) -> Payload {
        if let failure = errors.first(where: { $0.type != "NOT_FOUND" }) { throw .graphQL(type: failure.type, message: failure.message) }
        guard let data else { throw .malformed("data が無い") }
        return data
    }
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct Connection<Node: Decodable>: Decodable {
    let pageInfo: PageInfo
    let nodes: [Node?]
}

struct PostNode: Decodable {
    let id: String
    let body: String
    let viewerDidAuthor: Bool

    var post: DiscussionPost { DiscussionPost(id: id, body: body, viewerDidAuthor: viewerDidAuthor) }
}

struct CommentNode: Decodable {
    let id: String
    let body: String
    let viewerDidAuthor: Bool
    let replies: Connection<PostNode>

    var post: DiscussionPost { DiscussionPost(id: id, body: body, viewerDidAuthor: viewerDidAuthor) }
}

struct CategoryNode: Decodable {
    let id: String
    let name: String
}

struct CategoryNodes: Decodable {
    let nodes: [CategoryNode?]
}

struct RepositoryData: Decodable {
    struct Repository: Decodable {
        let id: String
        let hasDiscussionsEnabled: Bool
        let discussionCategories: CategoryNodes
    }

    let repository: Repository?
}

struct DiscussionData: Decodable {
    struct Discussion: Decodable {
        let id: String
        let number: Int
        let title: String
        let body: String
        let viewerDidAuthor: Bool
        let comments: Connection<CommentNode>
    }

    struct Repository: Decodable {
        let discussion: Discussion?
    }

    let repository: Repository?
}

struct DiscussionsData: Decodable {
    struct Node: Decodable {
        let id: String
        let number: Int
        let body: String
        let createdAt: String
        let viewerDidAuthor: Bool
    }

    struct Repository: Decodable {
        let discussions: Connection<Node>
    }

    let repository: Repository?
}

struct RepliesData: Decodable {
    struct Node: Decodable {
        let replies: Connection<PostNode>?
    }

    let node: Node?
}

struct NodesData: Decodable {
    struct Node: Decodable {
        let id: String
    }

    let nodes: [Node?]
}

struct CreatedNode: Decodable {
    let id: String
}

struct CreateDiscussionData: Decodable {
    struct Created: Decodable {
        let id: String
        let number: Int
    }

    struct Payload: Decodable {
        let discussion: Created?
    }

    let createDiscussion: Payload?
}

struct UpdateDiscussionData: Decodable {
    struct Payload: Decodable {
        let discussion: CreatedNode?
    }

    let updateDiscussion: Payload?
}

struct AddCommentData: Decodable {
    struct Payload: Decodable {
        let comment: CreatedNode?
    }

    let addDiscussionComment: Payload?
}

struct UpdateCommentData: Decodable {
    struct Payload: Decodable {
        let comment: CreatedNode?
    }

    let updateDiscussionComment: Payload?
}
