import AskHubKit
import Foundation

extension GitHubOrchestrator {
    public func conflictingEpicFinalPullRequests(orgs: [String]) async throws -> [ConflictingPullRequest] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let nodes: [ConflictPullRequestNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.conflictQuery,
                variables: [
                    "query": .string("\(scope) is:pr is:open label:\(AskHubLabel.epicFinal.rawValue)"),
                    "after": after.map(GraphQLVariable.string) ?? .null
                ],
                as: ConflictSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        // GitHub がまだ判定していない（UNKNOWN）ものは、次のポーリングで判定済みになってから扱う
        return nodes.compactMap { node in
            guard node.mergeable == "CONFLICTING", let number = node.number,
                  let repository = node.repository?.nameWithOwner, let head = node.headRefName, let base = node.baseRefName,
                  let headSHA = node.headRefOid, let baseSHA = node.baseRefOid else {
                return nil
            }
            return ConflictingPullRequest(
                repository: repository, number: number, headBranch: head, baseBranch: base, headSHA: headSHA, baseSHA: baseSHA
            )
        }
        .sorted { ($0.repository, $0.number) < ($1.repository, $1.number) }
    }

    public func comment(onPullRequest number: Int, in repository: String, body: String) async throws {
        _ = try await client.send(
            "POST",
            "repos/\(repository)/issues/\(number)/comments",
            body: ["body": body],
            as: ConflictCommentID.self
        )
    }

    private static let conflictQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: ISSUE, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                number mergeable headRefName baseRefName headRefOid baseRefOid
                repository { nameWithOwner }
              }
            }
          }
        }
        """
}

private struct ConflictSearchData: Decodable {
    struct Search: Decodable {
        let pageInfo: GraphQLPageInfo
        /// GitHub の GraphQL は要素が `null` になりうる。PR 以外のノードは `{}` で返る
        let nodes: [ConflictPullRequestNode?]
    }

    let search: Search
}

private struct ConflictPullRequestNode: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String
    }

    let number: Int?
    let mergeable: String?
    let headRefName: String?
    let baseRefName: String?
    let headRefOid: String?
    let baseRefOid: String?
    let repository: Repository?
}

private struct ConflictCommentID: Decodable {
    let id: Int
}
