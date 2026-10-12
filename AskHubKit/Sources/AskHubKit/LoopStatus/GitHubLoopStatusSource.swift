import Foundation

/// GitHub の GraphQL API から、リポジトリごとの担当の印と状態用の Issue を取得する。
///
/// 検索ではなく `organization.repositories` を最後のページまでたどる（Search API の 30 回/分の制限と、検索の件数のずれを避ける）。
/// 状態用の Issue はリポジトリに 1 つの想定だが、誰でも同じラベルで作れるので、1 ページに収まらなければそのリポジトリだけ続きを取る。
/// ビルドの Mac の状態の Issue（`build-hosts`）も同じ問い合わせで取る（`labels:` は OR なので回数は増えない）。
/// どちらかは本文の目印で分ける（Issue のラベルは 1 ページに収まるとは限らないので、ラベルの一覧は読まない）。
/// 状態用の Issue のコメント（ループごとの状態）は、読む Issue だけを `loopStatusComments` で別に取る
public struct GitHubLoopStatusSource: LoopStatusSource {
    let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
        var repositories: [LoopStatusRepository] = []
        // レート制限を考えて、organization ごとに順番に取得する
        for org in orgs {
            repositories += try await loopStatusRepositories(org: org)
        }
        return repositories
    }

    private func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
        let nodes: [RepositoryNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.repositoriesQuery,
                variables: [
                    "org": .string(org),
                    "after": after.map(GraphQLVariable.string) ?? .null,
                    "label": .string(OrchestratorHeartbeat.labelName),
                    "statusLabels": Self.statusLabels
                ],
                as: RepositoriesData.self
            )
            guard let repositories = data.organization?.repositories else {
                throw GitHubError.invalidResponse
            }
            return (repositories.nodes.compactMap(\.self), repositories.pageInfo)
        }
        var repositories: [LoopStatusRepository] = []
        // レート制限を考えて、続きのあるリポジトリは順番に取得する
        for node in nodes {
            var issues = node.issues?.nodes.compactMap(\.self) ?? []
            if let pageInfo = node.issues?.pageInfo, pageInfo.hasNextPage {
                issues += try await remainingIssues(of: node.nameWithOwner, after: pageInfo.endCursor)
            }
            repositories.append(LoopStatusRepository(
                repository: node.nameWithOwner,
                heartbeatDescription: node.label?.description,
                // `build-hosts` の目印を読めるものだけを分け、ほかは今までどおり状態用の Issue として扱う
                issues: issues.compactMap(\.issue).filter { !$0.isBuildHosts },
                buildHostsIssues: issues.compactMap(\.issue).filter(\.isBuildHosts)
            ))
        }
        return repositories
    }

    /// 1 ページ目に収まらなかった状態用の Issue の続き
    private func remainingIssues(of repository: String, after cursor: String?) async throws -> [IssueNode] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let cursor else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            // 1 回目（`after` が `nil`）は、リポジトリの一覧で取った 1 ページ目の続きから
            let data = try await client.graphQL(
                Self.issuesQuery,
                variables: [
                    "owner": .string(parts[0]),
                    "name": .string(parts[1]),
                    "after": .string(after ?? cursor),
                    "statusLabels": Self.statusLabels
                ],
                as: IssuesData.self
            )
            guard let issues = data.repository?.issues else {
                throw GitHubError.invalidResponse
            }
            return (issues.nodes.compactMap(\.self), issues.pageInfo)
        }
    }

    /// 状態用の Issue のコメント（ループごとの状態）。続きのページも最後まで取る。
    /// リポジトリの一覧の問い合わせに入れ子で足すとコスト（GraphQL のレート制限の点数）が大きいので、読む Issue だけを別に取る
    public func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let nodes: [CommentNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.commentsQuery,
                variables: [
                    "owner": .string(parts[0]),
                    "name": .string(parts[1]),
                    "number": .int(number),
                    "after": after.map(GraphQLVariable.string) ?? .null
                ],
                as: CommentsData.self
            )
            guard let comments = data.repository?.issue?.comments else {
                throw GitHubError.invalidResponse
            }
            return (comments.nodes.compactMap(\.self), comments.pageInfo)
        }
        return nodes.compactMap(\.comment)
    }

    /// 一緒に取る Issue のラベル（どれかが付いたもの）
    private static var statusLabels: GraphQLVariable {
        .strings([LoopStatusReport.labelName, BuildHostsReport.labelName])
    }

    /// 本文は状態の目印と短い表だけなので、まとめて取っても大きくならない
    private static let issueFields = """
        pageInfo { hasNextPage endCursor }
        nodes { number url updatedAt body author { login } }
        """

    static let repositoriesQuery = """
        query($org: String!, $after: String, $label: String!, $statusLabels: [String!]!) {
          organization(login: $org) {
            repositories(first: 50, after: $after, isArchived: false) {
              pageInfo { hasNextPage endCursor }
              nodes {
                nameWithOwner
                label(name: $label) { description }
                issues(first: 20, states: OPEN, labels: $statusLabels, orderBy: { field: UPDATED_AT, direction: DESC }) {
                  \(issueFields)
                }
              }
            }
          }
        }
        """

    static let commentsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { databaseId updatedAt body author { login } }
              }
            }
          }
        }
        """

    static let issuesQuery = """
        query($owner: String!, $name: String!, $after: String, $statusLabels: [String!]!) {
          repository(owner: $owner, name: $name) {
            issues(first: 100, after: $after, states: OPEN, labels: $statusLabels, orderBy: { field: UPDATED_AT, direction: DESC }) {
              \(issueFields)
            }
          }
        }
        """
}

private struct RepositoriesData: Decodable {
    struct Organization: Decodable {
        let repositories: Repositories
    }

    struct Repositories: Decodable {
        let pageInfo: GraphQLPageInfo
        /// GitHub の GraphQL は要素が `null` になりうる
        let nodes: [RepositoryNode?]
    }

    let organization: Organization?
}

private struct RepositoryNode: Decodable {
    struct Label: Decodable {
        let description: String?
    }

    let nameWithOwner: String
    let label: Label?
    let issues: IssueConnection?
}

private struct IssuesData: Decodable {
    struct Repository: Decodable {
        let issues: IssueConnection
    }

    let repository: Repository?
}

private struct IssueConnection: Decodable {
    let pageInfo: GraphQLPageInfo
    let nodes: [IssueNode?]
}

private struct IssueNode: Decodable {
    struct Author: Decodable {
        let login: String
    }

    let number: Int?
    let url: URL?
    let updatedAt: Date?
    let body: String?
    let author: Author?

    var issue: LoopStatusIssue? {
        guard let number, let url, let updatedAt, let body else {
            return nil
        }
        return LoopStatusIssue(number: number, url: url, author: author?.login, updatedAt: updatedAt, body: body)
    }
}

private struct CommentsData: Decodable {
    struct Repository: Decodable {
        let issue: CommentedIssue?
    }

    let repository: Repository?
}

private struct CommentedIssue: Decodable {
    let comments: CommentConnection
}

private struct CommentConnection: Decodable {
    let pageInfo: GraphQLPageInfo
    let nodes: [CommentNode?]
}

private struct CommentNode: Decodable {
    let databaseId: Int?
    let updatedAt: Date?
    let body: String?
    let author: IssueNode.Author?

    var comment: LoopStatusComment? {
        guard let databaseId, let updatedAt, let body else {
            return nil
        }
        return LoopStatusComment(id: databaseId, author: author?.login, updatedAt: updatedAt, body: body)
    }
}

private extension LoopStatusIssue {
    /// ビルドの Mac の状態の目印（`ask-hub:build-hosts`）を読める
    var isBuildHosts: Bool {
        BuildHostsReport.parse(body) != nil
    }
}
