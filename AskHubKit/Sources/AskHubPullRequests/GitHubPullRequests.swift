import AskHubProtocol
import AskHubStateStore
import Foundation

/// ワーカーが子 PR と最終 PR を扱うための、1 つのリポジトリの GitHub の操作。
///
/// - PR の作成は、同じ head・base の開いた PR があれば作らずにそれを返す（作った後、記録する前にワーカーが落ちても二重に作らない。
///   `docs/renewal/architecture.md` の「二重処理を防ぐ」）
/// - マージは merge commit で、見た head の SHA を渡して固定する（承認やチェックの後に push された変更をマージしない）
/// - CI は `checks(at:policy:)`（`GitHubPullRequests+Checks.swift`）、レビューの指摘は `reviewFeedback(number:trusted:)`
///   （`GitHubPullRequests+Reviews.swift`）で読む
/// - 失敗は `PullRequestError` に分ける。上限は待ち時間つきで返すだけで、ここでは待たない（待つかどうかはジョブの側で決める）
public struct GitHubPullRequests: Sendable {
    public let repository: RepositoryFullName
    let api: GitHubAPI

    /// `token` はリポジトリの持ち主（organization・個人）を受け取り、その持ち主の fine-grained token を返す。
    /// 要求のたびに Keychain などから読む。値はログ・URL・エラーに出さない
    public init(
        repository: RepositoryFullName,
        apiBase: URL = URL(string: "https://api.github.com")!,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable (_ owner: String) async throws -> String
    ) {
        self.repository = repository
        api = GitHubAPI(repository: repository, apiBase: apiBase, transport: transport, now: now, token: token)
    }

    // MARK: - 作る・読む

    /// PR を作る。同じ head・base の開いた PR がすでにあれば、作らずにそれを返す（題と本文は変えない）
    public func openPullRequest(_ draft: PullRequestDraft) async throws(PullRequestError) -> OpenedPullRequest {
        try GitNames.checkBranch(draft.head)
        try GitNames.checkBranch(draft.base)
        if let existing = try await openPullRequest(head: draft.head, base: draft.base) {
            return OpenedPullRequest(pullRequest: existing, created: false)
        }
        let body = CreateBody(title: draft.title, head: draft.head, base: draft.base, body: draft.body)
        do throws(PullRequestError) {
            let (data, _) = try await api.send("POST", api.url("pulls"), body: body)
            let created = try GitHubAPI.decode(PullRequestPayload.self, from: data, what: "pulls").model()
            return OpenedPullRequest(pullRequest: created, created: true)
        } catch let .rejected(message) {
            // 調べた後に、ほかの試行が同じ head・base の PR を先に作った（422 の "A pull request already exists"）
            if let existing = try await openPullRequest(head: draft.head, base: draft.base) {
                return OpenedPullRequest(pullRequest: existing, created: false)
            }
            throw .rejected(message: message)
        }
    }

    /// 同じリポジトリの head から base への開いた PR。無ければ nil
    public func openPullRequest(head: String, base: String) async throws(PullRequestError) -> PullRequest? {
        try GitNames.checkBranch(head)
        try GitNames.checkBranch(base)
        let query = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "head", value: "\(repository.owner):\(head)"),
            URLQueryItem(name: "base", value: base),
            URLQueryItem(name: "per_page", value: "100")
        ]
        let pages = try await api.pages("pulls", query: query, as: [PullRequestPayload].self)
        // `head` の絞り込みは持ち主とブランチ名だけなので、同じ持ち主のほかのリポジトリ（フォーク）の PR を除く
        let match = pages.joined().first { payload in
            payload.head.ref == head && payload.base.ref == base
                && payload.head.repo?.fullName.lowercased() == repository.rawValue.lowercased()
        }
        return try match?.model()
    }

    /// PR の様子を読む
    public func pullRequest(number: Int) async throws(PullRequestError) -> PullRequest {
        try GitNames.checkNumber(number)
        return try await api.get("pulls/\(number)", as: PullRequestPayload.self).model()
    }

    // MARK: - マージ・片付け

    /// merge commit でマージする。`headSHA` は見た head の SHA で、GitHub はこれと今の head が違えば断る（`headChanged`）。
    ///
    /// 前の試行がマージした後に記録する前に落ちていても、同じ head でマージ済みなら成功として返す
    public func merge(
        number: Int,
        headSHA: String,
        commitTitle: String? = nil,
        commitMessage: String? = nil
    ) async throws(PullRequestError) -> MergedPullRequest {
        try GitNames.checkNumber(number)
        try GitNames.checkSHA(headSHA)
        let body = MergeBody(mergeMethod: "merge", sha: headSHA, commitTitle: commitTitle, commitMessage: commitMessage)
        do throws(PullRequestError) {
            let (data, _) = try await api.send("PUT", api.url("pulls/\(number)/merge"), body: body)
            let merged = try GitHubAPI.decode(MergeResponse.self, from: data, what: "merge")
            guard merged.merged else { throw .malformed("マージの応答の merged が false") }
            return MergedPullRequest(sha: merged.sha, mergedNow: true)
        } catch .conflict {
            throw .headChanged
        } catch let .notMergeable(message) {
            let current = try await pullRequest(number: number)
            if current.merged, current.headSHA == headSHA {
                return MergedPullRequest(sha: current.mergeCommitSHA, mergedNow: false)
            }
            throw .notMergeable(message: message)
        }
    }

    /// ブランチを消す。今の先頭が `expectedSHA`（マージした head）と違えば、マージの後に push されたものを失うので消さない（`headChanged`）
    @discardableResult
    public func deleteBranch(_ branch: String, expectedSHA: String) async throws(PullRequestError) -> BranchDeletion {
        try GitNames.checkBranch(branch)
        try GitNames.checkSHA(expectedSHA)
        guard let current = try await branchHead(branch) else { return .alreadyGone }
        guard current == expectedSHA else { throw .headChanged }
        do throws(PullRequestError) {
            _ = try await api.send("DELETE", api.url("git/refs/heads/\(branch)"))
            return .deleted
        } catch let .rejected(message) {
            // 読んだ後に消えた（GitHub は無い ref の削除を 422 で断る）
            if try await branchHead(branch) == nil { return .alreadyGone }
            throw .rejected(message: message)
        }
    }

    /// ブランチの先頭の SHA。無ければ nil
    public func branchHead(_ branch: String) async throws(PullRequestError) -> String? {
        try GitNames.checkBranch(branch)
        do throws(PullRequestError) {
            return try await api.get("git/ref/heads/\(branch)", as: RefPayload.self).object.sha
        } catch .notFound {
            return nil
        }
    }

    /// GitHub Actions の run の、落ちた job（と、それに依る job）だけを流し直す
    public func rerunFailedJobs(runID: Int) async throws(PullRequestError) {
        try GitNames.checkNumber(runID)
        _ = try await api.send("POST", api.url("actions/runs/\(runID)/rerun-failed-jobs"))
    }
}

// MARK: - 要求と応答の形

private struct CreateBody: Encodable, Sendable {
    let title: String
    let head: String
    let base: String
    let body: String
}

private struct MergeBody: Encodable, Sendable {
    let mergeMethod: String
    let sha: String
    let commitTitle: String?
    let commitMessage: String?

    enum CodingKeys: String, CodingKey {
        case mergeMethod = "merge_method"
        case sha
        case commitTitle = "commit_title"
        case commitMessage = "commit_message"
    }
}

private struct MergeResponse: Decodable {
    let sha: String?
    let merged: Bool
}

private struct RefPayload: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let object: Object
}
