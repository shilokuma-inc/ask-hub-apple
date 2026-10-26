import Foundation

/// 状態用の Issue（`loop-status`）1 つ分。author の判定前の取得結果
public struct LoopStatusIssue: Sendable, Equatable {
    public var number: Int
    public var url: URL
    /// 作った author。削除済みのアカウントなどで取れなければ `nil`
    public var author: String?
    public var updatedAt: Date
    public var body: String
    /// コメント（ループごとの状態。author の判定前）。取得元は一覧では取らず、`LoopStatusFetcher` が使う Issue のものだけを取って入れる
    public var comments: [LoopStatusComment]

    public init(number: Int, url: URL, author: String?, updatedAt: Date, body: String, comments: [LoopStatusComment] = []) {
        self.number = number
        self.url = url
        self.author = author
        self.updatedAt = updatedAt
        self.body = body
        self.comments = comments
    }
}

/// org のリポジトリ 1 つ分の、担当の印と状態用の Issue
public struct LoopStatusRepository: Sendable, Equatable {
    /// `owner/name`
    public var repository: String
    /// `askhub-orchestrator` の説明。ラベルが無ければ `nil`
    public var heartbeatDescription: String?
    /// open な `loop-status` の Issue（author を問わない）
    public var issues: [LoopStatusIssue]
    /// open な `build-hosts` の Issue（author を問わない）
    public var buildHostsIssues: [LoopStatusIssue]

    public init(
        repository: String,
        heartbeatDescription: String?,
        issues: [LoopStatusIssue],
        buildHostsIssues: [LoopStatusIssue] = []
    ) {
        self.repository = repository
        self.heartbeatDescription = heartbeatDescription
        self.issues = issues
        self.buildHostsIssues = buildHostsIssues
    }
}

/// 「ステータス」タブの 1 行（リポジトリ 1 つ）
public struct LoopStatusRow: Sendable, Equatable, Identifiable {
    /// 行に出す状態
    public enum Status: Sendable, Equatable {
        /// 担当 PC がいない（担当の印も状態の確認時刻も 30 分より古い）
        case unassigned
        /// 担当 PC はいるが、状態用の Issue がまだ無い・読めない（状態を書き出さない古いオーケストレーターなど）
        case notReported
        case reported(LoopStatusReport)
    }

    /// `owner/name`
    public var repository: String
    /// 信用する author が作った状態用の Issue から読んだ状態（1 行に出す 1 つ。`board` から選ぶ）
    public var report: LoopStatusReport?
    /// 状態用の Issue の本文とループごとのコメントから読んだ状態。信用する author の状態用の Issue が無ければ `nil`
    public var board: LoopStatusBoard?
    /// 状態用の Issue
    public var issueURL: URL?
    /// 担当の印（`askhub-orchestrator`）の最終確認の時刻
    public var lastSeen: Date?

    public init(
        repository: String, report: LoopStatusReport?, board: LoopStatusBoard? = nil, issueURL: URL? = nil, lastSeen: Date? = nil
    ) {
        self.repository = repository
        self.report = report
        self.board = board
        self.issueURL = issueURL
        self.lastSeen = lastSeen
    }

    /// GitHub はリポジトリ名の大文字小文字を区別しないので、小文字で見分ける（`LoopStatusOrganizationSection` の節と合わせる）
    public var id: String {
        repository.lowercased()
    }

    /// 担当 PC がいるか。担当の印か、状態の確認時刻のどちらかが新しければいる
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now) || report?.isAssigned(now: now) == true
    }

    public func status(now: Date) -> Status {
        guard isAssigned(now: now) else {
            return .unassigned
        }
        return report.map(Status.reported) ?? .notReported
    }

    /// ゴール元の Discussion の URL。番号が無ければ `nil`
    public var discussionURL: URL? {
        guard let discussion = report?.discussion else {
            return nil
        }
        return URL(string: "https://github.com/\(repository)/discussions/\(discussion)")
    }

    /// 取得したリポジトリを行にまとめ、リポジトリ名の順に返す。
    ///
    /// 担当の印か、信用する author の状態用の Issue があるリポジトリを行にする（担当 PC が古いものも「担当 PC なし」として出す）。
    /// 状態用の Issue は誰でも同じラベルで作れるので、信用する author が作ったものだけを読む（`statusIssue(in:trustedAuthors:)`）。
    /// コメント（ループごとの状態）は、その Issue のもののうち信用する author のものだけを読む（`LoopStatusBoard`）。
    /// 同じリポジトリが 2 回来たら（organization の設定の重複・大文字小文字だけ違う名前）、先に来たものだけを行にする
    /// （`List` の同じ `ForEach` に同じ id の行があると、差分を当てるときに落ちることがある）
    public static func rows(from repositories: [LoopStatusRepository], trustedAuthors: TrustedAuthors) -> [Self] {
        let unique = repositories.uniqued { $0.repository.lowercased() }
        return unique.compactMap { repository in
            let issue = statusIssue(in: repository.issues, trustedAuthors: trustedAuthors)
            let lastSeen = OrchestratorHeartbeat.lastSeen(in: repository.heartbeatDescription)
            // 本文を読めなくても（人が編集したなど）、信用する author の Issue があれば行は残す
            guard issue != nil || lastSeen != nil else {
                return nil
            }
            let board = issue.map { LoopStatusBoard(issueBody: $0.body, comments: $0.comments, trustedAuthors: trustedAuthors) }
            return Self(
                repository: repository.repository,
                report: board.flatMap(Self.report(of:)),
                board: board,
                issueURL: issue?.url,
                lastSeen: lastSeen
            )
        }
        .sorted { $0.repository.lowercased() < $1.repository.lowercased() }
    }

    /// 読む状態用の Issue。信用する author が作ったもののうち、目印（本文の新しい形・古い形）を読めるもので最も新しく更新されたもの。
    /// 読めるものが無ければ、信用する author の最も新しく更新されたもの（行と Issue へのリンクだけを出す）
    public static func statusIssue(in issues: [LoopStatusIssue], trustedAuthors: TrustedAuthors) -> LoopStatusIssue? {
        let trusted = issues
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.updatedAt, $0.number) > ($1.updatedAt, $1.number) }
        let readable = trusted.first { issue in
            LoopStatusBoard(issueBody: issue.body, comments: [], trustedAuthors: trustedAuthors).body != .unreadable
        }
        return readable ?? trusted.first
    }

    /// 1 行に出す状態。複数のループを並べるまでは、今までと同じ見た目になるように選ぶ:
    /// 古い形の本文ならそのループ（同じ Discussion のコメントが新しければそちら）、新しい形なら自動ループ（書き手が `orchestrator`）、
    /// 無ければいずれかのループ。どちらも確認時刻（`checkedAt`）が最も新しいものを使う（終わったループのコメントが残っていても、今のループを出す）。
    /// ループが 1 つも無ければ、リポジトリ全体の状態から「ループなし」（上限で待機中ならその状態）を作る
    static func report(of board: LoopStatusBoard) -> LoopStatusReport? {
        if case let .loop(legacy) = board.body {
            return legacy.discussion.flatMap { board.loop(discussion: $0)?.report } ?? legacy
        }
        let automatic = board.loops.filter { $0.report.writer == .orchestrator }
        if let loop = (automatic.isEmpty ? board.loops : automatic).max(by: { $0.report.checkedAt < $1.report.checkedAt }) {
            return loop.report
        }
        return board.repository.map { repository in
            LoopStatusReport(
                state: repository.usageLimitedUntil == nil ? .noLoop : .usageLimited,
                usageLimitedUntil: repository.usageLimitedUntil,
                checkedAt: repository.checkedAt
            )
        }
    }
}

/// 「ステータス」タブの取得元。テストやサンプルデータでは差し替える
public protocol LoopStatusSource: Sendable {
    /// organization のアーカイブ済みでないリポジトリごとの、担当の印と open な状態用の Issue
    func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository]
    /// 状態用の Issue のコメント（古い順。author を問わない。続きのページも最後まで）
    func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment]
}

extension LoopStatusSource {
    /// コメントを持たない取得元（古い形の本文だけのサンプルなど）
    public func loopStatusComments(repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        []
    }
}

/// 「ステータス」タブに出す行を集める
public struct LoopStatusFetcher: Sendable {
    private let source: any LoopStatusSource
    private let trust: any TrustedAuthorsResolving

    /// - Parameter trustedAuthors: リポジトリごとの信用する author（固定の一覧なら `TrustedAuthors` をそのまま渡す）
    public init(source: any LoopStatusSource, trustedAuthors: any TrustedAuthorsResolving) {
        self.source = source
        self.trust = trustedAuthors
    }

    public func rows(orgs: [String]) async throws -> [LoopStatusRow] {
        try await status(orgs: orgs).rows
    }

    /// 「ステータス」タブの行と、ビルドの Mac の状態
    public func status(orgs: [String]) async throws -> LoopStatusSnapshot {
        var rows: [LoopStatusRow] = []
        var buildHosts: [BuildHostsStatus] = []
        // 状態用の Issue があるリポジトリだけ、信用する author を求める（organization の全リポジトリには問い合わせない）。
        // 同じリポジトリが 2 回来たら（organization の設定の重複など）、先に来たものだけを読む（行の id を重ねない・コメントを 2 回取らない）
        for var repository in try await source.loopStatusRepositories(orgs: orgs).uniqued(by: { $0.repository.lowercased() }) {
            let hasIssues = !repository.issues.isEmpty || !repository.buildHostsIssues.isEmpty
            let trusted = hasIssues ? await trust.trustedAuthors(for: repository.repository) : TrustedAuthors([])
            // コメントは、読む Issue（信用する author のもの）だけ取る。組織全体の問い合わせに入れ子で足すとコストが大きいため
            if let issue = LoopStatusRow.statusIssue(in: repository.issues, trustedAuthors: trusted),
               let index = repository.issues.firstIndex(of: issue) {
                repository.issues[index].comments = try await source.loopStatusComments(
                    repository: repository.repository, issue: issue.number
                )
            }
            rows += LoopStatusRow.rows(from: [repository], trustedAuthors: trusted)
            buildHosts += BuildHostsStatus.statuses(from: repository, trustedAuthors: trusted)
        }
        return LoopStatusSnapshot(
            rows: rows.sorted { $0.repository.lowercased() < $1.repository.lowercased() },
            // 書き手は 1 台の Mac だけの想定。複数のリポジトリにあれば、最も新しく確かめたものを使う
            buildHosts: buildHosts.max { ($0.report.checkedAt, $0.repository) < ($1.report.checkedAt, $1.repository) }
        )
    }
}

/// `LoopStatusFetcher.status(orgs:)` の結果
public struct LoopStatusSnapshot: Sendable, Equatable {
    public var rows: [LoopStatusRow]
    /// ビルドの Mac の状態。信用する author の `build-hosts` の Issue が無ければ `nil`
    public var buildHosts: BuildHostsStatus?

    public init(rows: [LoopStatusRow], buildHosts: BuildHostsStatus? = nil) {
        self.rows = rows
        self.buildHosts = buildHosts
    }
}

/// ビルドの Mac の状態の Issue（`build-hosts`）から読んだもの
public struct BuildHostsStatus: Sendable, Equatable {
    /// Issue を置いたリポジトリ（`owner/name`）
    public var repository: String
    public var issueURL: URL
    public var report: BuildHostsReport

    public init(repository: String, issueURL: URL, report: BuildHostsReport) {
        self.repository = repository
        self.issueURL = issueURL
        self.report = report
    }

    /// 信用する author が作り、目印を読める Issue のうち最も新しく更新されたもの（public リポジトリでは誰でも同じラベルで作れる）
    static func statuses(from repository: LoopStatusRepository, trustedAuthors: TrustedAuthors) -> [Self] {
        let newest = repository.buildHostsIssues
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.updatedAt, $0.number) > ($1.updatedAt, $1.number) }
            .lazy
            .compactMap { issue in
                BuildHostsReport.parse(issue.body).map { Self(repository: repository.repository, issueURL: issue.url, report: $0) }
            }
            .first
        return newest.map { [$0] } ?? []
    }
}
