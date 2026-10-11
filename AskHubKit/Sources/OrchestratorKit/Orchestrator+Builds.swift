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
