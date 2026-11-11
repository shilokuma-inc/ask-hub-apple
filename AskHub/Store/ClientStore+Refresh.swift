import Foundation

// MARK: - 自動の取り直し

extension ClientStore {
    /// 例: GitHub の上限に当たりました。15:54 に戻ります
    static func rateLimitMessage(until: Date) -> String {
        "GitHub の上限に当たりました。\(RelativeTime.clock(until)) に戻ります"
    }

    /// GitHub の上限に当たって、自動の取り直しを休んでいるか
    var isRefreshPaused: Bool {
        refreshPausedUntil.map { $0 > currentDate() } == true
    }

    /// 画面を開いている間、決まった間隔で取り直す。呼び出し元の Task が取り消されると止まる。
    /// `relaxed`（Mac で前面でない）か、GitHub の REST の残りが少なければ間隔を延ばす。GitHub の上限に当たったら、戻る時刻まで休む
    func runAutoRefresh(relaxed: Bool = false) async {
        while !Task.isCancelled {
            let wait = delayBeforeAutoRefresh(relaxed: relaxed)
            guard wait <= .zero else {
                try? await Task.sleep(for: wait)
                continue
            }
            await refresh()
        }
    }

    /// 次の自動の取り直しまでの時間（0 以下なら今すぐ）。前の読み込みを終えてから間隔を空け、上限に当たっていれば戻る時刻まで待つ。
    /// 前面に戻って回し直したときも、前の読み込みから間隔が空いていなければ、すぐには読まない
    func delayBeforeAutoRefresh(relaxed: Bool, at instant: ContinuousClock.Instant = .now) -> Duration {
        let date = currentDate()
        // 残りが少なければ、最後の残りを司令塔に回す（司令塔が止まると、質問づくりも通知も止まる）
        let relaxed = relaxed || snapshot?.githubQuota(now: date)?.isLow(now: date) == true
        let interval = service.refreshInterval
        let spacing = relaxed ? max(interval, Self.relaxedRefreshInterval) : interval
        var delay = lastRefreshEndedAt.map { spacing - $0.duration(to: instant) } ?? .zero
        if let until = refreshPausedUntil {
            delay = max(delay, .seconds(until.timeIntervalSince(date)))
        }
        return delay
    }
}
