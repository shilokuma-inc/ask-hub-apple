import AskHubProtocol
import Foundation

/// 試行と生きている印の間隔（`docs/renewal/architecture.md` の「ジョブには貸し出しの期限を持たせる」）
public struct JobTiming: Sendable, Equatable {
    /// ワーカーが試行の `heartbeatAt` を書く間隔
    public var heartbeatInterval: Duration = .seconds(5 * 60)
    /// `heartbeatAt` がこれより古い実行中の試行は、止まったとみなす（貸し出しの期限）
    public var attemptStaleAfter: Duration = .seconds(15 * 60)
    /// Mac の `seenAt` がこれより古ければ、オフラインとみなす（ワーカーは 10 分程度ごとに書く）
    public var macStaleAfter: Duration = .seconds(30 * 60)

    public init() {}
}

/// 実行中の試行が、まだ動いているか
public enum AttemptLiveness: Equatable, Sendable {
    case alive
    /// Mac がオフライン（閉じた・再起動した）。失敗に数えない
    case macOffline
    /// Mac は動いているのに、試行の印が古い（ワーカーの中で止まった）
    case stalled

    /// `attempt` は実行中の試行。`mac` は試行を実行している Mac の生きている印（読めなければ nil）
    public static func of(_ attempt: AttemptFile, mac: MacFile?, now: Date, timing: JobTiming = JobTiming()) -> Self {
        guard isOlder(attempt.heartbeatAt, than: timing.attemptStaleAfter, now: now) else { return .alive }
        guard let mac, mac.mac == attempt.mac, !isOlder(mac.seenAt, than: timing.macStaleAfter, now: now) else { return .macOffline }
        return .stalled
    }

    static func isOlder(_ timestamp: Timestamp, than limit: Duration, now: Date) -> Bool {
        now.timeIntervalSince(timestamp.date) > Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
    }
}
