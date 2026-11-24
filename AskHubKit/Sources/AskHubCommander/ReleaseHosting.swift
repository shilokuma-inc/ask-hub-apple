import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 配信の後作業が使う、対象のリポジトリの GitHub の操作（本物は `GitHubReleaseHosting`。テストでは差し替える）
public protocol ReleaseHosting: Sendable {
    func workflowRuns(_ repo: RepositoryFullName, createdFrom from: Date, to: Date) async throws(PullRequestError) -> [ActionsRun]
    /// 実行の job（すべての試行）
    func runJobs(_ repo: RepositoryFullName, runID: Int) async throws(PullRequestError) -> [ActionsJob]
    /// job のログの先頭
    func jobLogHead(_ repo: RepositoryFullName, jobID: Int) async throws(PullRequestError) -> String
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
    /// ブランチの先頭。無ければ nil
    func branchHead(_ repo: RepositoryFullName, branch: String) async throws(PullRequestError) -> String?
    /// `sha` を指すブランチを作る。すでにあれば作らずに今の先頭を返す
    func createBranch(_ repo: RepositoryFullName, branch: String, at sha: String) async throws(PullRequestError) -> String
    /// `head` が `base` より進んでいる・遅れているコミットの数
    func compare(_ repo: RepositoryFullName, base: String, head: String) async throws(PullRequestError) -> (ahead: Int, behind: Int)
    /// `workflow_dispatch` のワークフローを起動する（App Store のスクショの撮影）。起動した実行の id が返らなければ nil
    func dispatchWorkflow(
        _ repo: RepositoryFullName,
        workflow: String,
        ref: String,
        inputs: [String: String]
    ) async throws(PullRequestError) -> DispatchedRun?
    /// 1 つの実行の今の様子
    func workflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> WorkflowRunDetail
    /// ワークフローの、ブランチで `workflow_dispatch` から起こした実行（新しい順。最初のページだけ）
    func dispatchedRuns(_ repo: RepositoryFullName, workflow: String, branch: String) async throws(PullRequestError) -> [WorkflowRunDetail]
    /// 実行を取り消す
    func cancelWorkflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError)
    /// 実行の artifact
    func runArtifacts(_ repo: RepositoryFullName, runID: Int) async throws(PullRequestError) -> [RunArtifact]
    /// artifact の zip
    func downloadArtifact(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> Data
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

    public func runJobs(_ repo: RepositoryFullName, runID: Int) async throws(PullRequestError) -> [ActionsJob] {
        try await github(repo).runJobs(runID: runID)
    }

    public func jobLogHead(_ repo: RepositoryFullName, jobID: Int) async throws(PullRequestError) -> String {
        try await github(repo).jobLogHead(jobID: jobID)
    }

    public func tagCommit(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> String? {
        try await github(repo).tagCommit(tag)
    }

    public func dispatchWorkflow(
        _ repo: RepositoryFullName,
        workflow: String,
        ref: String,
        inputs: [String: String]
    ) async throws(PullRequestError) -> DispatchedRun? {
        try await github(repo).dispatchWorkflow(workflow, ref: ref, inputs: inputs)
    }

    public func workflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> WorkflowRunDetail {
        try await github(repo).workflowRun(id: id)
    }

    public func dispatchedRuns(
        _ repo: RepositoryFullName,
        workflow: String,
        branch: String
    ) async throws(PullRequestError) -> [WorkflowRunDetail] {
        try await github(repo).dispatchedRuns(workflow, branch: branch)
    }

    public func cancelWorkflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) {
        try await github(repo).cancelWorkflowRun(id: id)
    }

    public func runArtifacts(_ repo: RepositoryFullName, runID: Int) async throws(PullRequestError) -> [RunArtifact] {
        try await github(repo).runArtifacts(runID: runID)
    }

    public func downloadArtifact(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> Data {
        try await github(repo).downloadArtifact(id: id)
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

    public func branchHead(_ repo: RepositoryFullName, branch: String) async throws(PullRequestError) -> String? {
        try await github(repo).branchHead(branch)
    }

    public func createBranch(_ repo: RepositoryFullName, branch: String, at sha: String) async throws(PullRequestError) -> String {
        try await github(repo).createBranch(branch, at: sha)
    }

    public func compare(
        _ repo: RepositoryFullName,
        base: String,
        head: String
    ) async throws(PullRequestError) -> (ahead: Int, behind: Int) {
        try await github(repo).compare(base: base, head: head)
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

    // MARK: - ログで確かめる（`find` で決まらなかったとき）

    /// job のログでビルドの番号を確かめる候補の数の上限。超えたら読まずに人に回す（読む数は、候補ごとに job の一覧とログの数だけ）
    public static let maximumRunsToRead = 5
    /// ログで探す、ビルドの番号の設定の名前
    static let buildSetting = "CURRENT_PROJECT_VERSION"

    /// job のログに、ビルドの番号を `build` にした跡があるか。xcodebuild の引数（`CURRENT_PROJECT_VERSION=<番号>`。
    /// `${{ }}` で渡した値はログで展開される）と、xcodebuild が始めに出すコマンドラインのビルドの設定（`CURRENT_PROJECT_VERSION = <番号>`）を探す
    public static func logShowsBuild(_ log: String, build: String) -> Bool {
        guard !build.isEmpty else { return false }
        let log = withoutEscapes(log)
        return log.ranges(of: buildSetting).contains { range in
            // ほかの名前の一部（`MY_CURRENT_PROJECT_VERSION`・`CURRENT_PROJECT_VERSION_SUFFIX`）は除く
            if range.lowerBound > log.startIndex, isNamePart(log[log.index(before: range.lowerBound)]) { return false }
            var rest = log[range.upperBound...].drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else { return false }
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" }
            return rest.prefix { isNamePart($0) || $0 == "." } == build
        }
    }

    /// ログでビルドの番号を確かめた候補から決める。head が 1 つにそろえば、そのうち最後に始まった実行。そろわない・無ければ nil
    public static func pick(confirmed runs: [ActionsRun]) -> ActionsRun? {
        guard Set(runs.map(\.headSHA)).count == 1 else { return nil }
        return runs.max { $0.startedAt < $1.startedAt }
    }

    /// 端末のエスケープシーケンス（CSI: `ESC [ … <0x40〜0x7E>`）を除く。GitHub は `Run` の見出しのスクリプトを色付き（`ESC[36;1m … ESC[0m`）で出すので、
    /// 字下げの無い行では色の `m` の直後に名前が来る
    static func withoutEscapes(_ log: String) -> String {
        let escape: UInt8 = 0x1B
        guard log.utf8.contains(escape) else { return log }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(log.utf8.count)
        var iterator = log.utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == escape else {
                bytes.append(byte)
                continue
            }
            guard let next = iterator.next() else { break }
            guard next == UInt8(ascii: "[") else {
                bytes.append(next)
                continue
            }
            while let part = iterator.next(), !(0x40...0x7E).contains(part) {}
        }
        // 除くのは ASCII のバイトだけなので、UTF-8 のまま読める
        return String(bytes: bytes, encoding: .utf8) ?? log
    }

    private static func isNamePart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }
}
