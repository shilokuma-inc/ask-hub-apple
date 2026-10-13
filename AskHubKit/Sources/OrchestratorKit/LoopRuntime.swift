import Foundation

/// ループの状態の取得と起動。テストでは差し替える
public protocol LoopRuntime: Sendable {
    func status(of repository: RepositoryConfig) async -> LoopStatus
    /// `arguments` をシェルを経由せずに実行する。終了は待たない。
    /// `environment` は、この起動にだけ追加で渡す環境変数（起動の理由を起動スクリプトに伝えるのに使う）
    func launch(_ arguments: [String], environment: [String: String], for repository: RepositoryConfig) async throws
    /// 制御用 worktree のブランチ・ゴール・state を読む
    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot
    /// 最新のループ（準備を含む）が Claude の利用上限で終わっていれば、解除の時刻。そうでなければ `nil`
    func usageLimitReset(of repository: RepositoryConfig) async -> Date?
    /// ループのプロセスが生きているのに、今の周回が `timeout` より長く進んでいなければ、そのプロセス
    func hungLoop(of repository: RepositoryConfig, timeout: Duration, now: Date) async -> HungLoop?
    /// 固まったループのプロセスを止める（SIGTERM、猶予の後も残れば SIGKILL）
    func terminate(_ loop: HungLoop) async
    /// 「goal にタスクが無かった」目印を消す（Discussion に知らせた後。追記してラベルを付け直せば、もう一度準備する）
    func clearNoTasksMarker(of repository: RepositoryConfig) async
    /// ループが最後に動いた時刻（state ファイル・goal・最新のログの更新時刻のうち新しいもの）。無ければ `nil`
    func lastActivity(of repository: RepositoryConfig) async -> Date?
    /// `arguments` をシェルを経由せずに実行し、終わるまで待つ。`input` は標準入力に渡す。`timeout` を過ぎたら止める
    func run(_ arguments: [String], input: String, for repository: RepositoryConfig, timeout: Duration) async throws -> CommandResult
}

extension LoopRuntime {
    /// 追加の環境変数なしで `arguments` を実行する。終了は待たない
    public func launch(_ arguments: [String], for repository: RepositoryConfig) async throws {
        try await launch(arguments, environment: [:], for: repository)
    }
}

/// 終わるまで待って実行したコマンドの結果
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    /// 標準出力と標準エラー
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}
