import Foundation

/// ループのビルドの Mac（xcb）の情報を GitHub に書き出す設定（`orchestrator.json` の `buildHosts`）。
///
/// xcb を動かしている Mac のオーケストレーターだけが書く（Discussion #366）。キーが無ければこの機能を止める
/// （ほかの Mac のオーケストレーターや、xcb を使わない環境はそのまま動く）
public struct BuildHostsConfig: Sendable, Equatable {
    /// xcb のイベントログの既定のディレクトリ（xcb の `XCB_EVENTS_DIR` の既定と同じ）
    public static let defaultEventsDirectory = "~/Library/Logs/askhub/xcb"

    /// xcb の実行ファイルの絶対パス（`status --json` を呼ぶ）
    public let xcbPath: String
    /// xcb の `events.jsonl` を置くディレクトリの絶対パス
    public let eventsDirectory: String
    /// ビルドの Mac の状態の Issue（`build-hosts`）を置くリポジトリ（`owner/repo`）。無ければその Issue は書かない
    public let issueRepository: String?

    public init(xcbPath: String, eventsDirectory: String, issueRepository: String? = nil) {
        self.xcbPath = xcbPath
        self.eventsDirectory = eventsDirectory
        self.issueRepository = issueRepository
    }

    /// `build-hosts` の Issue を置く担当リポジトリ。設定が無い・担当から外れていれば `nil`（書かない）。
    /// 担当から外したときに設定ファイルごと読めなくならないよう、読み込みでは確かめずここで照らす
    public func issueRepository(in config: OrchestratorConfig) -> RepositoryConfig? {
        issueRepository.flatMap(config.repository(named:))
    }
}
