import AskHubKit
import Foundation

/// ビルドの Mac の状態の Issue（`build-hosts`）に、いつ何を書くかを決める（副作用なし）。
///
/// 書いた内容を覚えておき、状態（Mac の状態・実行中の本数・ループのビルド）が変わったときだけ本文を書き換える。
/// 変わらなければ `BuildHostsReport.updateInterval` ごとに確認時刻を書き直し、そのときだけ `xcb status --json` の
/// load・空きメモリを取り直して載せる（Discussion #366 の Q3。load・空きメモリの揺れは変化として扱わない）
public struct BuildHostsPublisher: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Issue をまだ覚えていない。一覧を取得して `adopt` してから決め直す
        case lookUp
        /// Issue を作る
        case create(body: String)
        /// 本文を書き換える（閉じられていれば開き直す）
        case update(number: Int, body: String)
        /// 書かない
        case none
    }

    struct Entry: Sendable, Equatable {
        /// Issue を置いたリポジトリ（`fullName` を小文字にしたもの）。設定が変わったら一覧から取り直す
        var repositoryKey: String
        var number: Int?
        /// 最後に書いた（Issue から読んだ）状態。読めない・閉じていれば `nil`（次は必ず書く）
        var report: BuildHostsReport?
    }

    private(set) var entry: Entry?
    /// レート制限で `Retry-After` を示されたときの、次に試してよい時刻
    private(set) var retryAt: Date?

    public init() {}

    /// load・空きメモリを取り直すか（確認時刻を書き直すとき。まだ書いていなければ取る）
    public func needsMeasurement(repositoryKey key: String, now: Date) -> Bool {
        guard let entry, entry.repositoryKey == key, let report = entry.report else {
            return true
        }
        return now.timeIntervalSince(report.checkedAt) >= BuildHostsReport.updateInterval
    }

    public func action(repositoryKey key: String, report: BuildHostsReport, now: Date) -> Action {
        if let retryAt, now < retryAt {
            return .none
        }
        guard let entry, entry.repositoryKey == key else {
            return .lookUp
        }
        guard let number = entry.number else {
            return .create(body: report.issueBody)
        }
        if let previous = entry.report, previous.hasSameStatus(as: report),
           now.timeIntervalSince(previous.checkedAt) < BuildHostsReport.updateInterval {
            return .none
        }
        return .update(number: number, body: report.issueBody)
    }

    /// 取得した Issue から使うものを覚える。信用する author が作ったもののうち、
    /// open なものの最も新しく更新されたもの、無ければ閉じたものの最も新しいもの（開き直して使う）
    public mutating func adopt(_ issues: [LoopStatusIssueRecord], repositoryKey key: String, trustedAuthors: TrustedAuthors) {
        let trusted = issues
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.isOpen ? 1 : 0, $0.updatedAt, $0.number) > ($1.isOpen ? 1 : 0, $1.updatedAt, $1.number) }
        guard let issue = trusted.first else {
            entry = Entry(repositoryKey: key, number: nil, report: nil)
            return
        }
        entry = Entry(repositoryKey: key, number: issue.number, report: issue.isOpen ? BuildHostsReport.parse(issue.body) : nil)
    }

    public mutating func recordWritten(_ report: BuildHostsReport, number: Int, repositoryKey key: String) {
        entry = Entry(repositoryKey: key, number: number, report: report)
        retryAt = nil
    }

    /// 書けなかった。次のポーリングで一覧から取り直す。レート制限なら `retryAfter` が過ぎるまで試さない
    public mutating func forget(retryAfter: Duration? = nil, now: Date = Date()) {
        entry = nil
        retryAt = retryAfter.map { now.addingTimeInterval(TimeInterval($0.components.seconds)) }
    }
}

extension BuildHostsReport {
    /// イベントから組み立てた Mac の状態（`XcbBuildTracker.hosts`）に、`xcb status --json` の値（コア数・load・空きメモリ・枠）を足す。
    ///
    /// Mac の並びは `xcb status --json` の順、イベントにしか出てこない Mac はその後ろ。状態・理由・実行中の本数は、
    /// 変わるたびに記録されるイベントのほうを使う（`xcb status --json` は最大 10 分古い）。イベントに出てこない Mac は `xcb status --json` の状態
    static func merging(
        hosts: [BuildHost],
        jobs: [BuildHostJob],
        status: XcbStatus?,
        measuredAt: Date?,
        checkedAt: Date
    ) -> Self {
        let fromEvents = Dictionary(hosts.map { ($0.name, $0) }) { first, _ in first }
        let measured = status?.hosts ?? []
        let measuredNames = Set(measured.map(\.name))
        var merged = measured.map { host in
            var result = fromEvents[host.name] ?? BuildHost(name: host.name, state: BuildHost.State(rawValue: host.state) ?? .unknown)
            result.cores = host.cores
            result.load = host.load
            result.memoryFreePercent = host.memoryFreePercent
            result.slots = host.slots
            if fromEvents[host.name] == nil {
                result.running = host.running
            }
            return result
        }
        merged += hosts.filter { !measuredNames.contains($0.name) }
        return BuildHostsReport(hosts: merged, jobs: jobs, measuredAt: status == nil ? nil : measuredAt, checkedAt: checkedAt)
    }
}
