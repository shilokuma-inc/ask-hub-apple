import AskHubKit
import Foundation

/// xcb のイベントログから組み立てた、ループのスロットのビルドと Mac の状態（設定の `buildHosts` があるときだけ）
struct BuildActivity: Sendable {
    /// 読み直しが要る設定（イベントログの場所・担当リポジトリ）。変わったら頭から読み直す
    struct Source: Sendable, Equatable {
        let eventsDirectory: String
        let repositories: [RepositoryConfig]
    }

    let source: Source
    private var reader: XcbEventLogReader
    private(set) var tracker: XcbBuildTracker

    init(source: Source) {
        self.source = source
        reader = XcbEventLogReader(directory: URL(fileURLWithPath: source.eventsDirectory, isDirectory: true))
        let resolver = BuildSlotResolver(repositories: source.repositories)
        tracker = XcbBuildTracker { path in
            resolver.slot(forPath: path).map { (repository: $0.repository, slot: $0.slot) }
        }
    }

    /// 前回の続きのイベントを取り込み、古くなったものを捨てる
    mutating func refresh(now: Date) {
        tracker.apply(reader.readNewEvents())
        tracker.prune(now: now)
    }
}

// xcb のビルドの情報を `loop-status` に載せる（Discussion #366）
extension Orchestrator {
    /// xcb のイベントログを読み進める。設定の `buildHosts` が無ければ止める（覚えていたものも捨てる）
    func refreshBuildActivity() {
        guard let settings = config.buildHosts else {
            buildActivity = nil
            return
        }
        let source = BuildActivity.Source(eventsDirectory: settings.eventsDirectory, repositories: config.repositories)
        if buildActivity?.source != source {
            buildActivity = BuildActivity(source: source)
        }
        buildActivity?.refresh(now: now())
    }

    /// リポジトリのループのスロットのビルド。機能が止まっている・ビルドが 1 つも無ければ `nil`（目印にキーを書かない）
    func builds(for repository: RepositoryConfig) -> LoopStatusBuilds? {
        guard let builds = buildActivity?.tracker.builds(for: repository.fullName), !builds.isEmpty else {
            return nil
        }
        return builds
    }
}

// ビルドの Mac の状態を `build-hosts` の Issue に書き出す（Discussion #366 の Q2・Q3）
extension Orchestrator {
    /// 設定の `buildHosts.issueRepository` があり、担当リポジトリのときだけ書く。`refreshBuildActivity()` の後に呼ぶ
    func publishBuildHosts(now current: Date) async {
        guard let settings = config.buildHosts, let repository = settings.issueRepository(in: config), let activity = buildActivity else {
            return
        }
        // load・空きメモリは、確認時刻を書き直すときだけ取り直す（各 Mac に ssh で問い合わせるので毎回は呼ばない）
        if buildHostsPublisher.needsMeasurement(lastAttemptAt: lastXcbStatusAttemptAt, now: current) {
            lastXcbStatusAttemptAt = current
            do {
                lastXcbStatus = (try await xcbStatus.status(xcbPath: settings.xcbPath), current)
            } catch {
                log("xcb status --json を読めませんでした（load・空きメモリは前の値のまま書きます）: \(error)")
            }
        }
        let report = BuildHostsReport.merging(
            hosts: activity.tracker.hosts,
            jobs: activity.tracker.hostJobs,
            status: lastXcbStatus?.status,
            measuredAt: lastXcbStatus?.measuredAt,
            checkedAt: current
        )
        do {
            try await publishBuildHosts(report, to: repository)
        } catch let GitHubError.rateLimited(retryAfter) {
            buildHostsPublisher.forget(retryAfter: retryAfter, now: current)
            log("\(repository.fullName) にビルドの Mac の状態を書けませんでした（レート制限。\(retryAfter.components.seconds) 秒後に再試行します）")
        } catch {
            buildHostsPublisher.forget()
            log("\(repository.fullName) にビルドの Mac の状態を書けませんでした（次のポーリングで再試行します）: \(error)")
        }
    }

    private func publishBuildHosts(_ report: BuildHostsReport, to repository: RepositoryConfig) async throws {
        let key = repository.fullName.lowercased()
        var action = buildHostsPublisher.action(repositoryKey: key, report: report, now: report.checkedAt)
        if action == .lookUp {
            let issues = try await github.buildHostsIssues(in: repository.fullName)
            buildHostsPublisher.adopt(issues, repositoryKey: key, trustedAuthors: trust.authors(for: repository.fullName))
            action = buildHostsPublisher.action(repositoryKey: key, report: report, now: report.checkedAt)
        }
        switch action {
        case .lookUp, .none:
            return

        case let .create(body):
            let number = try await github.createBuildHostsIssue(in: repository.fullName, body: body)
            buildHostsPublisher.recordWritten(report, number: number, repositoryKey: key)
            log("\(repository.fullName) にビルドの Mac の状態の Issue #\(number) を作りました")

        case let .update(number, body):
            try await github.updateBuildHostsIssue(in: repository.fullName, number: number, body: body)
            buildHostsPublisher.recordWritten(report, number: number, repositoryKey: key)
        }
    }
}
