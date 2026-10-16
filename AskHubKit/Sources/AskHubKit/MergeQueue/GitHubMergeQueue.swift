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
        for node in nodes {
            guard var pullRequest = node.pullRequest,
                  await trustedAuthors.trustedAuthors(for: pullRequest.repository).contains(pullRequest.author) else {
                continue
            }
            // contexts が 1 ページ（100 件）に収まらない PR は、残りを取り直してから CI の状態を決める（1 ページ目だけで黙って決めない）
            if let contexts = node.rollupContexts, contexts.pageInfo.hasNextPage {
                guard let cursor = contexts.pageInfo.endCursor else {
                    throw GitHubError.invalidResponse
                }
                let rest = try await remainingContexts(of: pullRequest, after: cursor)
                pullRequest.checks = EpicNode.checks(contexts.nodes.compactMap(\.self) + rest)
            }
            trusted.append(pullRequest)
        }
        return trusted
    }

    /// 検索で取れた最初のページより後ろの `statusCheckRollup.contexts` を、最後まで取る。
    /// 検索の後に push されても同じコミットの続きを取るよう、`commits(last: 1)` ではなく確認した head のコミットを指定する
    private func remainingContexts(of pullRequest: EpicPullRequest, after cursor: String) async throws -> [RollupContextNode] {
        let parts = pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.contextsQuery,
                variables: [
                    "owner": .string(parts[0]), "name": .string(parts[1]), "oid": .string(pullRequest.headSHA),
                    "after": .string(after ?? cursor)
                ],
                as: ContextsData.self
            )
            guard let contexts = data.repository?.object?.statusCheckRollup?.contexts else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (contexts.nodes.compactMap(\.self), contexts.pageInfo)
        }
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
                commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { ...Contexts } } } } }
              }
            }
          }
        }
        \(contextsFragment)
        """

    /// 1 ページ目に収まらなかった `statusCheckRollup.contexts` を、head のコミットを指定して取り直す
    private static let contextsQuery = """
        query($owner: String!, $name: String!, $oid: GitObjectID!, $after: String) {
          repository(owner: $owner, name: $name) {
            object(oid: $oid) {
              ... on Commit { statusCheckRollup { contexts(first: 100, after: $after) { ...Contexts } } }
            }
          }
        }
        \(contextsFragment)
        """

    /// check run（GitHub Actions など）と commit status（CodeRabbit など）の一覧。
    /// CI の状態は check run だけから決め、commit status は情報としてだけ使う（Discussion #460）
    private static let contextsFragment = """
        fragment Contexts on StatusCheckRollupContextConnection {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion checkSuite { app { slug } } }
            ... on StatusContext { context state description }
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
            checks: Self.checks(rollupContexts?.nodes.compactMap(\.self) ?? []),
            mergeability: Self.mergeability(mergeable)
        )
    }

    /// 最新コミットの `statusCheckRollup.contexts`（検索で取れた 1 ページ目）
    var rollupContexts: RollupContexts? {
        commits?.nodes.compactMap(\.self).last?.commit.statusCheckRollup?.contexts
    }

    /// GitHub Actions の check run だけから CI の状態を決める。commit status（CodeRabbit など）は見ない（Discussion #460）。
    /// 1 つでも失敗なら失敗、失敗が無く 1 つでも実行中なら実行中、check run が 1 つも無ければ なし
    static func checks(_ contexts: [RollupContextNode]) -> EpicPullRequest.ChecksState {
        let runs = contexts.filter(\.isGitHubActionsCheckRun).map(\.checkRunState)
        if runs.contains(.failure) {
            return .failure
        }
        if runs.contains(.pending) {
            return .pending
        }
        return runs.isEmpty ? .none : .success
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
    let contexts: RollupContexts?
}

/// `statusCheckRollup.contexts`（ページングされる connection）
private struct RollupContexts: Decodable {
    let pageInfo: GraphQLPageInfo
    let nodes: [RollupContextNode?]
}

/// `CheckRun` か `StatusContext`。どちらのフィールドも optional に取り、`__typename` で見分ける
private struct RollupContextNode: Decodable {
    struct CheckSuite: Decodable {
        let app: CheckSuiteApp?
    }

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, checkSuite, context, state, description
    }

    let typename: String?
    // CheckRun
    let name: String?
    let status: String?
    let conclusion: String?
    let checkSuite: CheckSuite?
    // StatusContext
    let context: String?
    let state: String?
    let description: String?

    /// GitHub Actions が作った check run か（`checkSuite.app.slug` が `github-actions`）
    var isGitHubActionsCheckRun: Bool {
        typename == "CheckRun" && checkSuite?.app?.slug == "github-actions"
    }

    /// check run 1 件の状態。`status` が `COMPLETED` 以外（QUEUED / IN_PROGRESS / WAITING など）は実行中。
    /// `conclusion` が SUCCESS / NEUTRAL / SKIPPED なら成功、それ以外（FAILURE / TIMED_OUT / CANCELLED / ACTION_REQUIRED /
    /// STARTUP_FAILURE / STALE。知らない値や `null` も）は失敗として扱う
    var checkRunState: EpicPullRequest.ChecksState {
        guard status == "COMPLETED" else {
            return .pending
        }
        switch conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED":
            return .success

        default:
            return .failure
        }
    }
}

/// check run を作ったアプリ（GitHub Actions は `github-actions`）
private struct CheckSuiteApp: Decodable {
    let slug: String
}

/// `contextsQuery` のレスポンス。`object` が Commit 以外（または無い）なら `{}` / `null`
private struct ContextsData: Decodable {
    struct Repository: Decodable {
        let object: CommitNode.Commit?
    }

    let repository: Repository?
}
