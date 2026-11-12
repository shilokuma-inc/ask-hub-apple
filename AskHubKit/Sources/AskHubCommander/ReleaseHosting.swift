import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 配信の後作業が使う、対象のリポジトリの GitHub の操作（本物は `GitHubReleaseHosting`。テストでは差し替える）
public protocol ReleaseHosting: Sendable {
    func workflowRuns(_ repo: RepositoryFullName, createdFrom from: Date, to: Date) async throws(PullRequestError) -> [ActionsRun]
    func tagCommit(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> String?
    func createAnnotatedTag(_ repo: RepositoryFullName, _ tag: AnnotatedTag) async throws(PullRequestError)
    func release(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> PublishedRelease?
    func publishRelease(_ repo: RepositoryFullName, tag: String, body: String) async throws(PullRequestError) -> PublishedRelease
    func commitFiles(_ repo: RepositoryFullName, _ commit: VersionCommit) async throws(PullRequestError) -> String
    func openPullRequest(_ repo: RepositoryFullName, _ draft: PullRequestDraft) async throws(PullRequestError) -> PullRequest
    func pullRequest(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError) -> PullRequest
    /// `required` が nil なら、すべてのチェックを待つ
    func checks(_ repo: RepositoryFullName, at sha: String, required: Set<String>?) async throws(PullRequestError) -> CheckSummary
    func merge(_ repo: RepositoryFullName, number: Int, headSHA: String) async throws(PullRequestError) -> MergedPullRequest
}

/// 配信したコミットに付ける注釈付きのタグ
public struct AnnotatedTag: Sendable, Equatable {
    public var name: String
    public var commit: String
    public var message: String
    public var tagger: GitAuthor
    public var date: Date

    public init(name: String, commit: String, message: String, tagger: GitAuthor, date: Date) {
        self.name = name
        self.commit = commit
        self.message = message
        self.tagger = tagger
        self.date = date
    }
}

/// develop の版を上げるコミット（新しいブランチに作る）
public struct VersionCommit: Sendable, Equatable {
    /// パス → 書き換えた中身
    public var files: [String: String]
    /// 親にする base の先頭と、その tree
    public var snapshot: MarketingVersionSnapshot
    public var message: String
    public var author: GitAuthor
    public var date: Date
    public var branch: String

    public init(
        files: [String: String],
        snapshot: MarketingVersionSnapshot,
        message: String,
        author: GitAuthor,
        date: Date,
        branch: String
    ) {
        self.files = files
        self.snapshot = snapshot
        self.message = message
        self.author = author
        self.date = date
        self.branch = branch
    }
}

/// 持ち主ごとのトークンで、`GitHubPullRequests` を使って GitHub を操作する
public struct GitHubReleaseHosting: ReleaseHosting {
    public var transport: any HTTPTransport
    public var token: @Sendable (_ owner: String) async throws -> String

    public init(
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        token: @escaping @Sendable (_ owner: String) async throws -> String
    ) {
        self.transport = transport
        self.token = token
    }

    private func github(_ repo: RepositoryFullName) -> GitHubPullRequests {
        GitHubPullRequests(repository: repo, transport: transport, token: token)
    }

    public func workflowRuns(
        _ repo: RepositoryFullName,
        createdFrom from: Date,
        to: Date
    ) async throws(PullRequestError) -> [ActionsRun] {
        try await github(repo).workflowRuns(createdFrom: from, to: to)
    }

    public func tagCommit(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> String? {
        try await github(repo).tagCommit(tag)
    }

    public func createAnnotatedTag(_ repo: RepositoryFullName, _ tag: AnnotatedTag) async throws(PullRequestError) {
        try await github(repo).createAnnotatedTag(
            tag.name,
            commit: tag.commit,
            message: tag.message,
            tagger: GitIdentity(name: tag.tagger.name, email: tag.tagger.email),
            date: tag.date
        )
    }

    public func release(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> PublishedRelease? {
        try await github(repo).release(tag: tag)
    }

    public func publishRelease(_ repo: RepositoryFullName, tag: String, body: String) async throws(PullRequestError) -> PublishedRelease {
        try await github(repo).publishRelease(tag: tag, body: body)
    }

    public func commitFiles(_ repo: RepositoryFullName, _ commit: VersionCommit) async throws(PullRequestError) -> String {
        try await github(repo).commitFiles(FileCommit(
            files: commit.files,
            base: commit.snapshot.head,
            baseTree: commit.snapshot.tree,
            message: commit.message,
            author: GitIdentity(name: commit.author.name, email: commit.author.email),
            date: commit.date,
            branch: commit.branch
        ))
    }

    public func openPullRequest(_ repo: RepositoryFullName, _ draft: PullRequestDraft) async throws(PullRequestError) -> PullRequest {
        try await github(repo).openPullRequest(draft).pullRequest
    }

    public func pullRequest(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError) -> PullRequest {
        try await github(repo).pullRequest(number: number)
    }

    public func checks(
        _ repo: RepositoryFullName,
        at sha: String,
        required: Set<String>?
    ) async throws(PullRequestError) -> CheckSummary {
        try await github(repo).checks(at: sha, policy: CheckPolicy(required: required))
    }

    public func merge(_ repo: RepositoryFullName, number: Int, headSHA: String) async throws(PullRequestError) -> MergedPullRequest {
        try await github(repo).merge(number: number, headSHA: headSHA)
    }
}

/// 配信したビルドから、そのビルドを上げた Upload の実行を探し、配信したコミットを決める（`docs/renewal/release.md` の「後作業の段取り」の 1）
public enum ReleaseCommitFinder {
    /// Upload のワークフローのファイル
    public static let uploadWorkflow = ".github/workflows/upload.yml"
    /// 上げた時刻より前に、実行が作られたとみなす長さ（Archive と Export を含めた Upload の長さより十分に長く）
    public static let lookBack: TimeInterval = 6 * 60 * 60
    /// 実行の最後の更新の後に、上げた時刻が来てもよい長さ（App Store Connect の記録の時刻のずれ）
    public static let endSlack: TimeInterval = 15 * 60
    /// 実行の始まりの前に、上げた時刻が来てもよい長さ（時計のずれ）
    public static let startSlack: TimeInterval = 60

    public enum Outcome: Equatable, Sendable {
        case found(ActionsRun)
        /// 上げた時刻に動いていた Upload の実行が無い
        case notFound
        /// 違うコミットの候補が残った
        case ambiguous([ActionsRun])
    }

    /// 上げた時刻に動いていた Upload の実行のうち、head が 1 つにそろえばそれ。そろわなければ、実行番号がビルドの番号と同じものに絞る
    /// （ビルドの番号を実行番号にするリポジトリ）。番号だけでは決めない（Xcode に採番させるリポジトリや、実行番号にする前のビルドがあるため）
    public static func find(in runs: [ActionsRun], build: String, uploadedAt: Date) -> Outcome {
        let candidates = runs.filter { run in
            run.path == uploadWorkflow
                && run.startedAt.addingTimeInterval(-startSlack) <= uploadedAt
                && uploadedAt <= run.updatedAt.addingTimeInterval(endSlack)
        }
        guard !candidates.isEmpty else { return .notFound }
        let numbered = candidates.filter { String($0.runNumber) == build }
        if Set(candidates.map(\.headSHA)).count == 1 {
            // 同じコミットの実行がいくつかあれば（develop と release/** で同時に走ったなど）、番号の合うもの、無ければ上げた時刻の直前に始まったもの
            let latest = candidates.max { $0.startedAt < $1.startedAt } ?? candidates[0]
            return .found(numbered.first ?? latest)
        }
        if !numbered.isEmpty, Set(numbered.map(\.headSHA)).count == 1 {
            return .found(numbered[0])
        }
        return .ambiguous(candidates.sorted { $0.startedAt < $1.startedAt })
    }
}
