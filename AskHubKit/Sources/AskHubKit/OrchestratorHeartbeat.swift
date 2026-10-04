import Foundation

/// オーケストレーターが担当リポジトリに残す「担当している」印（ラベル `askhub-orchestrator` の説明の時刻）。
///
/// アプリは担当 PC を知らないので、この時刻が新しいかで「担当 PC なし」を判断する
public enum OrchestratorHeartbeat {
    /// 印を書くラベルの名前
    public static let labelName = "askhub-orchestrator"
    /// オーケストレーターが印を書き直す間隔
    public static let updateInterval: TimeInterval = 10 * 60
    /// この時間より古い印は、担当 PC がいないとみなす（書き直しの間隔に余裕を持たせる）
    public static let freshness: TimeInterval = 30 * 60

    private static let prefix = "AskHub のオーケストレーターが担当（最終確認: "
    private static let suffix = "）"

    /// ラベルの説明。GitHub のラベルの説明は 100 文字まで
    public static func description(at date: Date) -> String {
        prefix + date.formatted(.iso8601) + suffix
    }

    /// ラベルの説明から最終確認の時刻を読む。形式が違えば `nil`
    public static func lastSeen(in description: String?) -> Date? {
        guard let description, description.hasPrefix(prefix), description.hasSuffix(suffix) else {
            return nil
        }
        let text = description.dropFirst(prefix.count).dropLast(suffix.count)
        return try? Date(String(text), strategy: .iso8601)
    }

    /// 担当 PC がいるか（印が `freshness` より新しいか）
    public static func isAssigned(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else {
            return false
        }
        return now.timeIntervalSince(lastSeen) <= freshness
    }
}

/// `ready-for-loop` が付いて、ループの開始を待っている Discussion
public struct WaitingDiscussion: Sendable, Equatable, Identifiable {
    public var subject: InboxSubject
    /// リポジトリの `askhub-orchestrator` の最終確認の時刻。印が無ければ `nil`
    public var lastSeen: Date?

    public init(subject: InboxSubject, lastSeen: Date?) {
        self.subject = subject
        self.lastSeen = lastSeen
    }

    public var id: String {
        subject.nodeID
    }

    /// 担当 PC がいるか
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now)
    }
}
