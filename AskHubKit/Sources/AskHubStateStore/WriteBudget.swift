import Foundation

/// 書き手ごとの書き込みの予算（`docs/renewal/architecture.md` の「状態リポジトリの書き方」）。
///
/// GitHub の内容を作る要求の上限（同じアカウントで 1 分 80 件・1 時間 500 件）を、クライアント・司令塔・全ワーカーで分け合うため、
/// 書き手ごとに 1 分と 1 時間の上限を持つ。予算を超えた書き込みは送らずに `budgetExhausted` にする
public actor WriteBudget {
    public struct Limits: Sendable, Equatable {
        public var perMinute: Int
        public var perHour: Int

        public init(perMinute: Int, perHour: Int) {
            self.perMinute = perMinute
            self.perHour = perHour
        }

        /// 最初の値。今の仕組みを止めた後に、実際の書き込みの量を見て決め直す
        public static let commander = Self(perMinute: 20, perHour: 200)
        public static let worker = Self(perMinute: 10, perHour: 60)
        public static let client = Self(perMinute: 10, perHour: 40)
    }

    public let limits: Limits
    private var times: [Date] = []

    public init(limits: Limits) {
        self.limits = limits
    }

    /// 1 件書いてよいかを確かめ、よければ数える
    public func reserve(now: Date) throws(StateStoreError) {
        times.removeAll { now.timeIntervalSince($0) >= 3600 }
        let lastMinute = times.filter { now.timeIntervalSince($0) < 60 }
        // 上限が 0 以下なら、数えた書き込みが無くても書かない（1 つの枠の長さだけ待たせる）
        if lastMinute.count >= limits.perMinute {
            let until = lastMinute.min().map { $0.addingTimeInterval(60) } ?? now.addingTimeInterval(60)
            throw .budgetExhausted(retryAfter: Self.wait(until: until, now: now))
        }
        if times.count >= limits.perHour {
            let until = times.min().map { $0.addingTimeInterval(3600) } ?? now.addingTimeInterval(3600)
            throw .budgetExhausted(retryAfter: Self.wait(until: until, now: now))
        }
        times.append(now)
    }

    private static func wait(until date: Date, now: Date) -> Duration {
        .seconds(Int(max(date.timeIntervalSince(now), 0).rounded(.up)))
    }
}
