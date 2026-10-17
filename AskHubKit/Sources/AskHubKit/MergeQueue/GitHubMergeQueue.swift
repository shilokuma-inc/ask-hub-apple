import Foundation

/// GitHub の API で「マージ待ち」を取得し、マージする
public struct GitHubMergeQueue: MergeQueueProviding {
    let client: GitHubClient
    private let trustedAuthors: any TrustedAuthorsResolving
    private let uploadWorkflow: (any UploadWorkflowProviding)?

    /// - Parameters:
    ///   - trustedAuthors: 信用する author が作った PR だけを出す（ラベルは書き込み権限があれば誰でも付けられる）
    ///   - uploadWorkflow: 最終 PR ごとに Upload ワークフローの直近の run を読む。`nil` なら読まない（`uploadStatus` は `notLoaded`）
    public init(
        client: GitHubClient,
        trustedAuthors: any TrustedAuthorsResolving = TrustedAuthors.default,
        uploadWorkflow: (any UploadWorkflowProviding)? = nil
    ) {
        self.client = client
        self.trustedAuthors = trustedAuthors
        self.uploadWorkflow = uploadWorkflow
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
            guard var pullRequest = node.pullRequest else {
                continue
            }
            let authors = await trustedAuthors.trustedAuthors(for: pullRequest.repository)
            guard authors.contains(pullRequest.author) else {
                continue
            }
            // contexts が 1 ページ（100 件）に収まらない PR は、残りを取り直してから CI と CodeRabbit の状態を決める（1 ページ目だけで黙って決めない）
            if let contexts = node.rollupContexts, contexts.pageInfo.hasNextPage {
                guard let cursor = contexts.pageInfo.endCursor else {
                    throw GitHubError.invalidResponse
                }
                let all = try await contexts.nodes.compactMap(\.self) + remainingContexts(of: pullRequest, after: cursor)
                pullRequest.checks = EpicNode.checks(all)
                pullRequest.codeRabbit = EpicNode.codeRabbit(all)
                pullRequest.headSince = node.headSince(codeRabbitCreatedAt: EpicNode.codeRabbitCreatedAt(all))
            }
            // 第三者レビューの目印と進み具合は、PR のコメントを最後まで読んでから決める（状態コメントは古いコメントを書き換えて使うため）
            var comments = node.comments?.nodes.compactMap(\.self) ?? []
            if let page = node.comments, page.pageInfo.hasNextPage {
                guard let cursor = page.pageInfo.endCursor else {
                    throw GitHubError.invalidResponse
                }
                comments += try await remainingComments(of: pullRequest, after: cursor)
            }
            Self.attachFinalReview(to: &pullRequest, comments: comments, trustedAuthors: authors)
            trusted.append(pullRequest)
        }
        return try await attachUploadStatus(to: trusted)
    }

    /// 最終 PR ごとに Upload ワークフローの直近の run を読んで付ける。リポジトリ・ブランチが同じ PR は 1 回の取得を共有し、
    /// ワークフローが無い（404）リポジトリは 2 本目以降のブランチも読まない。
    /// 取得に失敗しても、マージ待ちそのもの（PR・CI・コンフリクト・まとめ）は返す。
    /// ただし取得が打ち切られた（キャンセル）ときは投げ、呼び出し側が前の状態に戻せるようにする。
    /// レート制限で待てなくなったら、残りは読まずに `unavailable` にする（キーの数だけ待ち時間を重ねない）
    private func attachUploadStatus(to pullRequests: [EpicPullRequest]) async throws -> [EpicPullRequest] {
        guard let uploadWorkflow else {
            return pullRequests
        }
        var statuses: [UploadKey: EpicPullRequest.UploadStatus] = [:]
        var unsupportedRepositories: Set<String> = []
        var rateLimited = false
        var result = pullRequests
        for index in result.indices {
            let key = UploadKey(repository: result[index].repository, branch: result[index].headBranch)
            if statuses[key] == nil {
                if unsupportedRepositories.contains(key.repository) {
                    statuses[key] = .unsupported
                } else if rateLimited {
                    statuses[key] = .unavailable
                } else {
                    let status = try await Self.uploadStatus(uploadWorkflow, repository: key.repository, branch: key.branch)
                    statuses[key] = status.status
                    rateLimited = status.rateLimited
                    if status.status == .unsupported {
                        unsupportedRepositories.insert(key.repository)
                    }
                }
            }
            result[index].uploadStatus = statuses[key] ?? .unavailable
        }
        return result
    }

    /// 1 つのリポジトリ・ブランチの run の状況と、レート制限で待てなくなったか
    private static func uploadStatus(
        _ uploadWorkflow: any UploadWorkflowProviding,
        repository: String,
        branch: String
    ) async throws -> (status: EpicPullRequest.UploadStatus, rateLimited: Bool) {
        do {
            switch try await uploadWorkflow.latestRun(repository: repository, branch: branch) {
            case .unsupported:
                return (.unsupported, false)

            case .noRuns:
                return (.noRuns, false)

            case .run(let run):
                return (.run(run), false)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch UploadWorkflowError.permissionDenied {
            return (.permissionDenied, false)
        } catch GitHubError.rateLimited {
            return (.unavailable, true)
        } catch {
            // 打ち切られた取得（URLSession のキャンセル）は失敗として確定させない
            if Task.isCancelled {
                throw CancellationError()
            }
            return (.unavailable, false)
        }
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
                id number title body url createdAt baseRefName headRefName headRefOid mergeable
                author { login }
                repository { nameWithOwner defaultBranchRef { name } }
                headRepository { nameWithOwner }
                commits(last: 1) { nodes { commit { committedDate statusCheckRollup { contexts(first: 100) { ...Contexts } } } } }
                comments(first: 100) { ...Comments }
              }
            }
          }
        }
        \(contextsFragment)
        \(commentsFragment)
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
    /// CI の状態は check run だけから決め（Discussion #460）、commit status `CodeRabbit` は最終 PR のレビューの条件に使う（Discussion #503）
    private static let contextsFragment = """
        fragment Contexts on StatusCheckRollupContextConnection {
          pageInfo { hasNextPage endCursor }
          nodes {
            __typename
            ... on CheckRun { name status conclusion checkSuite { app { slug } } }
            ... on StatusContext { context state description createdAt }
          }
        }
        """
}

// MARK: - リクエストとレスポンスの形

/// run の取得をまとめる単位（リポジトリ・ブランチごとに 1 回）
private struct UploadKey: Hashable {
    let repository: String
    let branch: String
}

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
    let createdAt: Date?
    let baseRefName: String?
    let headRefName: String?
    let headRefOid: String?
    let mergeable: String?
    let author: Login?
    let repository: Repository?
    let headRepository: HeadRepository?
    let commits: Commits?
    let comments: PullRequestComments?

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
            mergeability: Self.mergeability(mergeable),
            codeRabbit: Self.codeRabbit(rollupContexts?.nodes.compactMap(\.self) ?? []),
            headSince: headSince(codeRabbitCreatedAt: Self.codeRabbitCreatedAt(rollupContexts?.nodes.compactMap(\.self) ?? []))
        )
    }

    /// 今の head を GitHub が受け取った時刻の推定。CodeRabbit の commit status の時刻、無ければ head のコミットの日時。
    /// PR を開く前のコミット（epic の head は古いことが多い）で、開いたばかりの PR をすぐレビューしないよう、PR の作成時刻を下限にする
    func headSince(codeRabbitCreatedAt: Date?) -> Date? {
        guard let estimate = codeRabbitCreatedAt ?? headCommittedDate else {
            return createdAt
        }
        return createdAt.map { max($0, estimate) } ?? estimate
    }

    /// 最新コミットの日時（commit status `CodeRabbit` が無いときの、head を見始めた時刻の代わり）
    var headCommittedDate: Date? {
        commits?.nodes.compactMap(\.self).last?.commit.committedDate
    }

    /// commit status `CodeRabbit` の時刻（rollup は最新の status なので、CodeRabbit が状態を書き換えた時刻）。
    /// head の push を受け取った時刻以後になるので、待ち始めを遅らせる側（CodeRabbit を長めに待つ側）にずれる
    static func codeRabbitCreatedAt(_ contexts: [RollupContextNode]) -> Date? {
        contexts.first { $0.typename == "StatusContext" && $0.context == "CodeRabbit" }?.createdAt
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

    /// commit status `CodeRabbit` から CodeRabbit の状態を決める。完了は最終 PR のレビューの条件になる（Discussion #503）。
    /// `PENDING` / `EXPECTED` → 処理中、`SUCCESS` は `description` の文言で レート制限・スキップ・完了 を見分け、どれにも当たらなければ 不明、
    /// `ERROR` / `FAILURE` → 失敗、無ければ なし（知らない `state` も なし）。
    /// 完了でマージできるようになるので、CodeRabbit が文言を変えたときは完了ではなく 不明 に倒す（レビュー済みにしない）
    static func codeRabbit(_ contexts: [RollupContextNode]) -> EpicPullRequest.CodeRabbitState {
        guard let status = contexts.first(where: { $0.typename == "StatusContext" && $0.context == "CodeRabbit" }) else {
            return .none
        }
        switch status.state {
        case "PENDING", "EXPECTED":
            return .inProgress

        case "SUCCESS":
            return codeRabbitSuccess(status.description)

        case "ERROR", "FAILURE":
            return .failed

        default:
            return .none
        }
    }

    /// `SUCCESS` の commit status `CodeRabbit` の `description` から、完了・レート制限・スキップを見分ける（大文字小文字は区別しない）。
    /// "completed" を含むときだけ完了。`description` が無い・知らない文言は 不明
    private static func codeRabbitSuccess(_ description: String?) -> EpicPullRequest.CodeRabbitState {
        guard let description else {
            return .unknown
        }
        if description.range(of: "rate limited", options: .caseInsensitive) != nil {
            return .rateLimited
        }
        if description.range(of: "skipped", options: .caseInsensitive) != nil {
            return .skipped
        }
        if description.range(of: "completed", options: .caseInsensitive) != nil {
            return .completed
        }
        return .unknown
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
        /// 取り直し（`contextsQuery`）では読まないので optional
        let committedDate: Date?
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
        case name, status, conclusion, checkSuite, context, state, description, createdAt
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
    let createdAt: Date?

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
