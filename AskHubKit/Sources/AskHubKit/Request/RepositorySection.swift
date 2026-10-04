import Foundation

/// 依頼先の候補のリポジトリ
public struct RequestRepository: Equatable, Sendable {
    /// `owner/repo`
    public var fullName: String
    /// `askhub-orchestrator` の最終確認の時刻。印が無ければ `nil`
    public var lastSeen: Date?

    public init(fullName: String, lastSeen: Date? = nil) {
        self.fullName = fullName
        self.lastSeen = lastSeen
    }

    /// 担当 PC がいるか
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now)
    }
}

/// 依頼先の Picker に出すリポジトリのまとまり（Discussion #115 Q5: Picker のまま Section で分ける。
/// 区切り方は PR #136 の回答で「担当 PC の有無」）
public struct RepositorySection: Equatable, Sendable, Identifiable {
    public let title: String
    /// `owner/repo`。元の一覧の順（最近 push された順）を保つ
    public let repositories: [String]

    public var id: String { title }

    public init(title: String, repositories: [String]) {
        self.title = title
        self.repositories = repositories
    }

    /// 担当 PC がいるものとそれ以外に分ける。候補は絞らず（Q4）、空のまとまりは返さない
    public static func grouping(_ repositories: [RequestRepository], now: Date) -> [Self] {
        let assigned = repositories.filter { $0.isAssigned(now: now) }.map(\.fullName)
        let others = repositories.filter { !$0.isAssigned(now: now) }.map(\.fullName)
        return [
            Self(title: "担当 PC あり", repositories: assigned),
            Self(title: "担当 PC なし", repositories: others)
        ]
        .filter { !$0.repositories.isEmpty }
    }
}
