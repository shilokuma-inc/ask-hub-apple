import Foundation

/// オーケストレーターが担当リポジトリに残す「担当している」印（ラベル `askhub-orchestrator` の説明の時刻）。
///
/// アプリは担当 PC を知らないので、この時刻が新しいかで「担当 PC なし」を判断する
public enum OrchestratorHeartbeat {
    /// 印を書くラベルの名前
    public static let labelName = AskHubLabel.orchestratorHeartbeat.rawValue
    /// オーケストレーターが印を書き直す間隔
    public static let updateInterval: TimeInterval = 10 * 60
    /// この時間より古い印は、担当 PC がいないとみなす（書き直しの間隔に余裕を持たせる）
    public static let freshness: TimeInterval = 30 * 60

    private static let prefix = "AskHub のオーケストレーターが担当（最終確認: "
    private static let limitSeparator = "・上限で待機中: "
    private static let suffix = "）"

    /// ラベルの説明。GitHub のラベルの説明は 100 文字まで（上限の時刻を足しても 80 文字ほど）
    /// - Parameter usageLimitedUntil: Claude の利用上限で待機しているときの、解除の時刻
    public static func description(at date: Date, usageLimitedUntil: Date? = nil) -> String {
        var text = prefix + date.formatted(.iso8601)
        if let usageLimitedUntil {
            text += limitSeparator + usageLimitedUntil.formatted(.iso8601)
        }
        return text + suffix
    }

    /// ラベルの説明から最終確認の時刻を読む。形式が違えば `nil`
    public static func lastSeen(in description: String?) -> Date? {
        fields(in: description)?.lastSeen
    }

    /// ラベルの説明から、利用上限の解除の時刻を読む。待機していない・形式が違えば `nil`
    public static func usageLimitedUntil(in description: String?) -> Date? {
        fields(in: description)?.usageLimitedUntil
    }

    private static func fields(in description: String?) -> (lastSeen: Date, usageLimitedUntil: Date?)? {
        guard let description, description.hasPrefix(prefix), description.hasSuffix(suffix) else {
            return nil
        }
        let text = String(description.dropFirst(prefix.count).dropLast(suffix.count))
        let parts = text.components(separatedBy: limitSeparator)
        guard parts.count <= 2, let lastSeen = try? Date(parts[0], strategy: .iso8601) else {
            return nil
        }
        if parts.count == 2 {
            guard let until = try? Date(parts[1], strategy: .iso8601) else {
                return nil
            }
            return (lastSeen, until)
        }
        return (lastSeen, nil)
    }

    /// 利用上限で待機しているか（解除の時刻が `now` より後か）
    public static func isUsageLimited(until: Date?, now: Date) -> Bool {
        guard let until else {
            return false
        }
        return until > now
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
    /// Discussion を作った author。削除済みのアカウントなどで取れなければ `nil`
    public var author: String?
    /// 担当 PC が Claude の利用上限で待機しているときの、解除の時刻
    public var usageLimitedUntil: Date?

    public init(subject: InboxSubject, lastSeen: Date?, author: String? = nil, usageLimitedUntil: Date? = nil) {
        self.subject = subject
        self.lastSeen = lastSeen
        self.author = author
        self.usageLimitedUntil = usageLimitedUntil
    }

    public var id: String {
        subject.nodeID
    }

    /// 担当 PC がいるか
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now)
    }

    /// 担当 PC が利用上限で待機しているか
    public func isUsageLimited(now: Date) -> Bool {
        isAssigned(now: now) && OrchestratorHeartbeat.isUsageLimited(until: usageLimitedUntil, now: now)
    }
}

/// 担当 PC が Claude の利用上限で待機しているリポジトリ
public struct UsageLimitedRepository: Sendable, Equatable, Identifiable {
    /// `owner/name`
    public var repository: String
    /// 解除の時刻（この時刻を過ぎたら、オーケストレーターが止まっていたループを再開する）
    public var until: Date

    public init(repository: String, until: Date) {
        self.repository = repository
        self.until = until
    }

    public var id: String {
        repository
    }
}
