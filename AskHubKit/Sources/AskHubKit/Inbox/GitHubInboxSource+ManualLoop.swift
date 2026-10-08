import Foundation

/// 手動ループ（`manual-loop` の open な Discussion）1 つ分。author と担当者の判定前の取得結果
public struct ManualLoopRecord: Sendable, Equatable {
    public var subject: InboxSubject
    /// Discussion のコメント（古い順。最後の 100 件まで）。担当のコメントを探すのに使う
    public var comments: [ManualLoopComment]

    public init(subject: InboxSubject, comments: [ManualLoopComment]) {
        self.subject = subject
        self.comments = comments
    }
}

/// 手動ループの Discussion のコメント
public struct ManualLoopComment: Sendable, Equatable {
    /// 削除済みのユーザーでは `nil`
    public var author: String?
    public var body: String

    public init(author: String?, body: String) {
        self.author = author
        self.body = body
    }
}

/// 手動ループの epic。ステータスタブの「手動ループ」に出す
public struct ManualLoopEpic: Sendable, Equatable, Identifiable {
    /// ゴール元の Discussion
    public var subject: InboxSubject
    /// 担当者の login。担当のコメントが無ければ `nil`
    public var assignee: String?

    public init(subject: InboxSubject, assignee: String?) {
        self.subject = subject
        self.assignee = assignee
    }

    public var id: String {
        subject.nodeID
    }

    /// 始めるときに Claude Code に渡す指示
    public var startInstruction: String {
        ManualLoopInstruction.start(repository: subject.repository, discussionNumber: subject.number)
    }

    /// 再開するときに Claude Code に渡す指示
    public var resumeInstruction: String {
        ManualLoopInstruction.resume(repository: subject.repository, discussionNumber: subject.number)
    }
}

extension GitHubInboxSource {
    /// `manual-loop` が付いた open な Discussion と、そのコメント（最後の 100 件）
    public func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let query = "\(scope) label:\(AskHubLabel.manualLoop.rawValue) is:open"
        let nodes: [ManualLoopNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.manualLoopQuery,
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
                as: ManualLoopSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        return nodes.compactMap { node in
            guard let id = node.id, let number = node.number, let title = node.title, let url = node.url,
                  let repository = node.repository?.nameWithOwner, node.closed != true else {
                return nil
            }
            let subject = InboxSubject(
                kind: .discussion,
                nodeID: id,
                repository: repository,
                number: number,
                title: title,
                url: url,
                author: node.author?.login,
                labels: [AskHubLabel.manualLoop.rawValue]
            )
            let comments = (node.comments?.nodes ?? []).compactMap(\.self).map {
                ManualLoopComment(author: $0.author?.login, body: $0.body ?? "")
            }
            return ManualLoopRecord(subject: subject, comments: comments)
        }
    }

    static let manualLoopQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: DISCUSSION, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on Discussion {
                id number title url closed
                author { login }
                repository { nameWithOwner }
                comments(last: 100) { nodes { author { login } body } }
              }
            }
          }
        }
        """
}

private struct ManualLoopSearchData: Decodable {
    struct Search: Decodable {
        let pageInfo: GraphQLPageInfo
        let nodes: [ManualLoopNode?]
    }

    let search: Search
}

/// `manual-loop` の Discussion。フラグメントに合わないノードは `{}` で返るので、フィールドはすべて optional にする
private struct ManualLoopNode: Decodable {
    struct Login: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Comments: Decodable {
        let nodes: [Comment?]
    }

    struct Comment: Decodable {
        let author: Login?
        let body: String?
    }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let closed: Bool?
    let author: Login?
    let repository: Repository?
    let comments: Comments?
}
