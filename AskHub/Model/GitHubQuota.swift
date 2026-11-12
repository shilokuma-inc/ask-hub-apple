import AskHubProtocol
import Foundation

/// GitHub の REST の上限の残り。司令塔とワーカーが生きている印に書いたもの（`docs/renewal/operations.md` の「GitHub の上限」）。
///
/// 上限はアカウントごとに数えるので、このアプリ・司令塔・Claude のセッションの `gh` が同じ回数を分け合う
struct GitHubQuota: Hashable {
    /// 1 時間の上限（ふつうは 5,000）
    var limit: Int
    var remaining: Int
    /// 今の窓が終わり、`limit` に戻る時刻
    var resetAt: Date
    /// Mac が読んだ時刻（生きている印の自己診断の時刻）
    var checkedAt: Date

    /// 今の窓の値か。戻る時刻を過ぎていれば、読んだ残りはもう古い
    func isCurrent(now: Date) -> Bool {
        now < resetAt
    }

    /// 残りが少ないか（司令塔が知らせるのと同じしきい値）
    func isLow(now: Date) -> Bool {
        remaining < GitHubRateLimit.lowRemaining && isCurrent(now: now)
    }

    /// 例: 4,210
    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "ja_JP")))
    }
}
