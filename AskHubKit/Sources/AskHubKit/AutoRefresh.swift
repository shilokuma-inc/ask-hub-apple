import Foundation

/// 一覧の自動更新（Discussion #1 の Q7: フォアグラウンド復帰時と、iOS の Background App Refresh。
/// Issue #299: アプリを開いているあいだの定期の取り直し）。
///
/// 一覧の取得には Search API を数回使う（認証済みで 30 回/分）。アプリを切り替えるたびに取り直さないよう、間隔を空ける
public enum AutoRefresh {
    /// アプリを開いているあいだ、全タブの一覧を取り直す間隔。オーケストレーターのポーリングの既定（60 秒）に合わせる
    public static let foregroundInterval: Duration = .seconds(60)
    /// 直前の取得からこの時間がたっていなければ、自動では取り直さない。
    /// 定期の取り直し（`foregroundInterval` ごと）が、直前の取得の時刻とのわずかなずれで 1 回飛ばないよう、間隔より短くする
    public static let minimumInterval: TimeInterval = 50
    /// Background App Refresh を次に実行してよい最短の間隔（実際に実行する時刻は OS が決める）
    public static let backgroundInterval: TimeInterval = 15 * 60

    /// 自動で取り直すか。まだ一度も取得していなければ取り直す
    public static func isStale(lastRefreshed: Date?, now: Date, interval: TimeInterval = minimumInterval) -> Bool {
        guard let lastRefreshed else {
            return true
        }
        return now.timeIntervalSince(lastRefreshed) >= interval
    }

    /// `interval` ごとに `action` を実行する。最初の実行は `interval` の後。呼び出した Task が取り消されるまで続く
    public static func repeating(
        every interval: Duration,
        isolation: isolated (any Actor)? = #isolation,
        _ action: () async -> Void
    ) async {
        while true {
            do {
                try await Task.sleep(for: interval)
            } catch {
                // 取り消された（アプリがバックグラウンドに移った・画面が閉じた）
                return
            }
            await action()
        }
    }
}
