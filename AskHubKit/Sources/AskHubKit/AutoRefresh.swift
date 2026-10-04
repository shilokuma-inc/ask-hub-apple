import Foundation

/// 一覧の自動更新（Discussion #1 の Q7: フォアグラウンド復帰時と、iOS の Background App Refresh）。
///
/// 一覧の取得には Search API を数回使う（認証済みで 30 回/分）。アプリを切り替えるたびに取り直さないよう、間隔を空ける
public enum AutoRefresh {
    /// 直前の取得からこの時間がたっていなければ、自動では取り直さない
    public static let minimumInterval: TimeInterval = 60
    /// Background App Refresh を次に実行してよい最短の間隔（実際に実行する時刻は OS が決める）
    public static let backgroundInterval: TimeInterval = 15 * 60

    /// 自動で取り直すか。まだ一度も取得していなければ取り直す
    public static func isStale(lastRefreshed: Date?, now: Date, interval: TimeInterval = minimumInterval) -> Bool {
        guard let lastRefreshed else {
            return true
        }
        return now.timeIntervalSince(lastRefreshed) >= interval
    }
}
