import AskHubProtocol
import Foundation

/// 失敗した試行の後に、ジョブをどうするか
public enum FailureDecision: Equatable, Sendable {
    /// 同じジョブを、`at` 以降にもう一度試す（Claude に直させない）
    case retry(at: Timestamp)
    /// Claude に直させて、もう一度試す（同じ会話を再開する）。`round` は何回目の直しか（1 から）
    case fix(round: Int)
    /// 人へ渡す。自動の対処を使い切ったか、自動では直せない
    case human
    /// Mac が戻るまで止める。試行の失敗に数えない
    case pause
}

/// 失敗の区分ごとの既定の扱い（`docs/renewal/architecture.md` の「失敗の区分と既定の扱い」）
public struct FailurePolicy: Sendable, Equatable {
    /// Claude に直させる回数の上限（ビルド・テストの失敗、レビューの必須の指摘、コンフリクト）
    public var maxFixRounds = 3
    /// ランナー不足の待ち。最初の待ちから倍にしていき、上限で止める。回数の上限は無い
    public var runnerWaitFirst: Duration = .seconds(10 * 60)
    public var runnerWaitMax: Duration = .seconds(60 * 60)
    /// GitHub の障害の待ち。続いた回数ごとに長くする
    public var outageWaits: [Duration] = [.seconds(60), .seconds(120), .seconds(300), .seconds(600), .seconds(1_800)]
    /// 利用上限で、解除の時刻が分からないときの待ち
    public var usageLimitWait: Duration = .seconds(60 * 60)

    public init() {}

    /// `failure` は今回の失敗、`earlier` は同じジョブのそれまでの失敗（古い順）
    public func decide(_ failure: FailureClass, retryAt: Timestamp?, earlier: [FailureClass], now: Date) -> FailureDecision {
        switch failure {
        case .runnerUnavailable:
            // 続いた回数で待ちを倍にする（10 分・20 分・40 分・60 分・60 分…）
            let streak = Self.trailingStreak(of: .runnerUnavailable, in: earlier)
            let wait = min(runnerWaitFirst * (1 << min(streak, 16)), runnerWaitMax)
            return .retry(at: Timestamp(now + wait))
        case .flaky:
            // 揺らぎは 1 回だけ流し直す。2 回目からはテストの失敗として直させる
            return earlier.contains(.flaky) ? fixOrHuman(earlier: earlier) : .retry(at: Timestamp(now))
        case .buildFailed, .testFailed, .reviewRequired, .conflict:
            return fixOrHuman(earlier: earlier)
        case .usageLimit:
            return .retry(at: retryAt ?? Timestamp(now + usageLimitWait))
        case .githubOutage:
            let streak = Self.trailingStreak(of: .githubOutage, in: earlier)
            return .retry(at: Timestamp(now + outageWaits[min(streak, outageWaits.count - 1)]))
        case .macOffline:
            return .pause
        case .timeout:
            // 1 回は試し直す。続けて時間切れになったら人へ（重いジョブは上限と実行する Mac を見直す）
            return earlier.last == .timeout ? .human : .retry(at: Timestamp(now))
        case .authExpired, .unexpected:
            return .human
        }
    }

    /// 直させた回数（今回を含む）が上限以内なら直させる
    private func fixOrHuman(earlier: [FailureClass]) -> FailureDecision {
        // 揺らぎは、最初の 1 回（流し直し）を除いて、直しに数える
        let flakyFixes = max(earlier.filter { $0 == .flaky }.count - 1, 0)
        let round = earlier.filter(Self.needsFix).count + flakyFixes + 1
        return round <= maxFixRounds ? .fix(round: round) : .human
    }

    private static func needsFix(_ failure: FailureClass) -> Bool {
        switch failure {
        case .buildFailed, .testFailed, .reviewRequired, .conflict: true
        default: false
        }
    }

    /// 末尾から、同じ区分の失敗が何回続いているか
    static func trailingStreak(of failure: FailureClass, in earlier: [FailureClass]) -> Int {
        earlier.reversed().prefix { $0 == failure }.count
    }
}

private func + (date: Date, duration: Duration) -> Date {
    date.addingTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
}
