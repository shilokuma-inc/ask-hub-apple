import Foundation

/// 状態用の Issue（`loop-status`）1 つ分。author の判定前の取得結果
public struct LoopStatusIssue: Sendable, Equatable {
    public var number: Int
    public var url: URL
    /// 作った author。削除済みのアカウントなどで取れなければ `nil`
    public var author: String?
    public var updatedAt: Date
    public var body: String

    public init(number: Int, url: URL, author: String?, updatedAt: Date, body: String) {
        self.number = number
        self.url = url
        self.author = author
        self.updatedAt = updatedAt
        self.body = body
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

    public init(repository: String, heartbeatDescription: String?, issues: [LoopStatusIssue]) {
        self.repository = repository
        self.heartbeatDescription = heartbeatDescription
        self.issues = issues
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
    /// 信用する author が作った状態用の Issue から読んだ状態
    public var report: LoopStatusReport?
    /// 状態用の Issue
    public var issueURL: URL?
    /// 担当の印（`askhub-orchestrator`）の最終確認の時刻
    public var lastSeen: Date?

    public init(repository: String, report: LoopStatusReport?, issueURL: URL? = nil, lastSeen: Date? = nil) {
        self.repository = repository
        self.report = report
        self.issueURL = issueURL
        self.lastSeen = lastSeen
    }

    public var id: String {
        repository
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
    /// 状態用の Issue は誰でも同じラベルで作れるので、信用する author が作ったものだけを読み、複数あれば目印を読めるうち最も新しく更新されたものを使う
    public static func rows(from repositories: [LoopStatusRepository], trustedAuthors: TrustedAuthors) -> [Self] {
        repositories.compactMap { repository in
            let trusted = repository.issues
                .filter { trustedAuthors.contains($0.author) }
                .sorted { ($0.updatedAt, $0.number) > ($1.updatedAt, $1.number) }
            let parsed = trusted.lazy.compactMap { issue in LoopStatusReport.parse(issue.body).map { (issue, $0) } }.first
            let lastSeen = OrchestratorHeartbeat.lastSeen(in: repository.heartbeatDescription)
            // 本文を読めなくても（人が編集したなど）、信用する author の Issue があれば行は残す
            guard !trusted.isEmpty || lastSeen != nil else {
                return nil
            }
            return Self(
                repository: repository.repository,
                report: parsed?.1,
                issueURL: parsed?.0.url ?? trusted.first?.url,
                lastSeen: lastSeen
            )
        }
        .sorted { $0.repository.lowercased() < $1.repository.lowercased() }
    }
}

/// 「ステータス」タブの取得元。テストやサンプルデータでは差し替える
public protocol LoopStatusSource: Sendable {
    /// organization のアーカイブ済みでないリポジトリごとの、担当の印と open な状態用の Issue
    func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository]
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
        var rows: [LoopStatusRow] = []
        // 状態用の Issue があるリポジトリだけ、信用する author を求める（organization の全リポジトリには問い合わせない）
        for repository in try await source.loopStatusRepositories(orgs: orgs) {
            let trusted = repository.issues.isEmpty ? TrustedAuthors([]) : await trust.trustedAuthors(for: repository.repository)
            rows += LoopStatusRow.rows(from: [repository], trustedAuthors: trusted)
        }
        return rows.sorted { $0.repository.lowercased() < $1.repository.lowercased() }
    }
}
