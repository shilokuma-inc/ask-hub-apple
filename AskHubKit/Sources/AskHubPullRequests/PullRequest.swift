import Foundation

/// 作る PR。head は同じリポジトリのブランチ
public struct PullRequestDraft: Sendable, Equatable {
    public var base: String
    public var head: String
    public var title: String
    public var body: String

    public init(base: String, head: String, title: String, body: String) {
        self.base = base
        self.head = head
        self.title = title
        self.body = body
    }
}

/// PR の様子
public struct PullRequest: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case open
        case closed
    }

    public var number: Int
    public var url: URL?
    public var state: State
    public var merged: Bool
    /// マージできるか。GitHub が計算中なら nil（少し後に読み直す）。一覧の応答には含まれないので nil
    public var mergeable: Bool?
    /// `clean`・`dirty`・`blocked`・`behind`・`unstable`・`unknown` など。一覧の応答には含まれないので nil
    public var mergeableState: String?
    public var headSHA: String
    public var headRef: String
    public var baseRef: String
    /// マージした後のマージコミット（マージ前は、GitHub が試しに作ったコミットのことがある）
    public var mergeCommitSHA: String?

    public init(
        number: Int,
        url: URL? = nil,
        state: State,
        merged: Bool,
        mergeable: Bool? = nil,
        mergeableState: String? = nil,
        head: (ref: String, sha: String),
        baseRef: String,
        mergeCommitSHA: String? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.merged = merged
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.headSHA = head.sha
        self.headRef = head.ref
        self.baseRef = baseRef
        self.mergeCommitSHA = mergeCommitSHA
    }
}

/// `openPullRequest` の結果
public struct OpenedPullRequest: Sendable, Equatable {
    public var pullRequest: PullRequest
    /// 今回作ったなら true。同じ head・base の開いた PR がすでにあれば false
    public var created: Bool

    public init(pullRequest: PullRequest, created: Bool) {
        self.pullRequest = pullRequest
        self.created = created
    }
}

/// マージの結果
public struct MergedPullRequest: Sendable, Equatable {
    /// マージコミット
    public var sha: String?
    /// 今回マージしたなら true。前の試行ですでにマージされていたら false
    public var mergedNow: Bool

    public init(sha: String?, mergedNow: Bool) {
        self.sha = sha
        self.mergedNow = mergedNow
    }
}

/// ブランチの削除の結果
public enum BranchDeletion: Sendable, Equatable {
    case deleted
    /// すでに無かった（前の試行で消した・GitHub の自動の削除）
    case alreadyGone
}

// MARK: - 応答の形（キーは `convertFromSnakeCase` で読む）

struct PullRequestPayload: Decodable {
    struct Branch: Decodable {
        let ref: String
        let sha: String
        /// フォークが消えると null になる
        let repo: RepositoryPayload?
    }

    let number: Int
    let htmlUrl: URL?
    let state: String
    /// 一覧の応答には無い（`merged_at` で見分ける）
    let merged: Bool?
    let mergedAt: String?
    let mergeable: Bool?
    let mergeableState: String?
    let mergeCommitSha: String?
    let head: Branch
    let base: Branch

    func model() throws(PullRequestError) -> PullRequest {
        guard let state = PullRequest.State(rawValue: state) else { throw .malformed("PR の state が \(state)") }
        return PullRequest(
            number: number,
            url: htmlUrl,
            state: state,
            merged: merged ?? (mergedAt != nil),
            mergeable: mergeable,
            mergeableState: mergeableState,
            head: (head.ref, head.sha),
            baseRef: base.ref,
            mergeCommitSHA: mergeCommitSha
        )
    }
}

struct RepositoryPayload: Decodable {
    let fullName: String
}
