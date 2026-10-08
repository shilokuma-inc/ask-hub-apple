import Foundation

/// GitHub の API で「マージ待ち」を取得し、マージする
public struct GitHubMergeQueue: MergeQueueProviding {
    private let client: GitHubClient
    private let trustedAuthors: any TrustedAuthorsResolving

    /// - Parameter trustedAuthors: 信用する author が作った PR だけを出す（ラベルは書き込み権限があれば誰でも付けられる）
    public init(client: GitHubClient, trustedAuthors: any TrustedAuthorsResolving = TrustedAuthors.default) {
        self.client = client
        self.trustedAuthors = trustedAuthors
    }

    public func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
        guard let scope = SearchScope.organizations(orgs) else {
            return []
        }
        let query = "\(scope) is:pr is:open label:\(AskHubLabel.epicFinal.rawValue)"
        let nodes: [EpicNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.searchQuery,
                variables: ["query": .string(query), "after": after.map(GraphQLVariable.string) ?? .null],
                as: EpicSearchData.self
            )
            return (data.search.nodes.compactMap(\.self), data.search.pageInfo)
        }
        // 最終 PR だけを出す: 同じリポジトリの epic ブランチから既定ブランチ（develop）への PR で、信用する author が作ったもの。
        // fork からの PR は、マージ後に削除するブランチがこのリポジトリに無いので扱わない
        var trusted: [EpicPullRequest] = []
        for pullRequest in nodes.compactMap(\.pullRequest)
        where await trustedAuthors.trustedAuthors(for: pullRequest.repository).contains(pullRequest.author) {
            trusted.append(pullRequest)
        }
        return trusted
    }

    public func merge(_ pullRequest: EpicPullRequest) async throws {
        if let reason = pullRequest.blockingReason {
            throw MergeQueueError.notMergeable(reason: reason)
        }
        // merge commit でマージする（Q13）。確認した head から更新されていれば GitHub が 409 で断る
        _ = try await client.send(
            "PUT",
            "repos/\(pullRequest.repository)/pulls/\(pullRequest.number)/merge",
            body: MergeRequest(mergeMethod: "merge", sha: pullRequest.headSHA),
            as: MergeResult.self
        )
        do {
            try await client.send("DELETE", "repos/\(pullRequest.repository)/git/refs/heads/\(pullRequest.headBranch)")
        } catch {
            throw MergeQueueError.branchNotDeleted(pullRequest.headBranch)
        }
    }

    private static let searchQuery = """
        query($query: String!, $after: String) {
          search(query: $query, type: ISSUE, first: 50, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                id number title body url baseRefName headRefName headRefOid mergeable
                author { login }
                repository { nameWithOwner defaultBranchRef { name } }
                headRepository { nameWithOwner }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
        }
        """
}

// MARK: - リクエストとレスポンスの形

private struct MergeRequest: Encodable, Sendable {
    let mergeMethod: String
    let sha: String

    private enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
        case sha
    }
}

private struct MergeResult: Decodable {
    let merged: Bool
}

private struct EpicSearchData: Decodable {
    struct Search: Decodable {
        let pageInfo: GraphQLPageInfo
        let nodes: [EpicNode?]
    }

    let search: Search
}

private struct EpicNode: Decodable {
    struct Login: Decodable {
        let login: String
    }

    struct Repository: Decodable {
        let nameWithOwner: String
        let defaultBranchRef: BranchRef?
    }

    struct Commits: Decodable {
        let nodes: [CommitNode?]
    }

    let id: String?
    let number: Int?
    let title: String?
    let body: String?
    let url: URL?
    let baseRefName: String?
    let headRefName: String?
    let headRefOid: String?
    let mergeable: String?
    let author: Login?
    let repository: Repository?
    let headRepository: HeadRepository?
    let commits: Commits?

    /// 検索の型に合わないノード（`{}`）では `nil`
    var pullRequest: EpicPullRequest? {
        guard let id, let number, let title, let url, let baseRefName, let headRefName, let headRefOid,
              let repository,
              // 既定ブランチ（develop）への PR だけ。fork や head のリポジトリが分からない PR は除く
              baseRefName == repository.defaultBranchRef?.name,
              headRepository?.nameWithOwner.caseInsensitiveCompare(repository.nameWithOwner) == .orderedSame else {
            return nil
        }
        return EpicPullRequest(
            id: id,
            repository: repository.nameWithOwner,
            number: number,
            title: title,
            body: body ?? "",
            url: url,
            baseBranch: baseRefName,
            headBranch: headRefName,
            headSHA: headRefOid,
            author: author?.login,
            checks: Self.checks(commits?.nodes.compactMap(\.self).last?.commit.statusCheckRollup?.state),
            mergeability: Self.mergeability(mergeable)
        )
    }

    /// `statusCheckRollup.state`（EXPECTED / ERROR / FAILURE / PENDING / SUCCESS）
    static func checks(_ state: String?) -> EpicPullRequest.ChecksState {
        switch state {
        case "SUCCESS":
            .success

        case "PENDING", "EXPECTED":
            .pending

        case "FAILURE", "ERROR":
            .failure

        default:
            .none
        }
    }

    static func mergeability(_ value: String?) -> EpicPullRequest.Mergeability {
        switch value {
        case "MERGEABLE":
            .mergeable

        case "CONFLICTING":
            .conflicting

        default:
            .unknown
        }
    }
}

private struct CommitNode: Decodable {
    struct Commit: Decodable {
        let statusCheckRollup: CheckRollup?
    }

    let commit: Commit
}

private struct BranchRef: Decodable {
    let name: String
}

private struct HeadRepository: Decodable {
    let nameWithOwner: String
}

private struct CheckRollup: Decodable {
    let state: String
}
