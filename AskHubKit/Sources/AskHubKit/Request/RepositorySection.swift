import Foundation

/// 依頼先の候補のリポジトリ
public struct RequestRepository: Equatable, Sendable {
    /// `owner/repo`
    public var fullName: String
    /// `askhub-orchestrator` の最終確認の時刻。印が無ければ `nil`
    public var lastSeen: Date?
    /// 担当の印を確認できたか。取得に失敗したときは `false`（印が無いのか分からない）
    public var isAssignmentKnown: Bool

    public init(fullName: String, lastSeen: Date? = nil, isAssignmentKnown: Bool = true) {
        self.fullName = fullName
        self.lastSeen = lastSeen
        self.isAssignmentKnown = isAssignmentKnown
    }

    /// 担当 PC がいるか
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: lastSeen, now: now)
    }
}

/// 依頼先の Picker に出すリポジトリのまとまり（Discussion #115 Q5: Picker のまま Section で分ける。
/// 区切り方は PR #136 の回答で「担当 PC の有無」、Discussion #572 Q1 でその中を owner ごとに分ける）
public struct RepositorySection: Equatable, Sendable, Identifiable {
    public let title: String
    /// `owner/repo`。元の一覧の順（最近 push された順）を保つ
    public let repositories: [String]

    public var id: String { title }

    public init(title: String, repositories: [String]) {
        self.title = title
        self.repositories = repositories
    }

    /// 担当 PC がいるものとそれ以外に分け、それぞれを owner ごとに分ける（Discussion #572 Q1。Picker の Section は入れ子にできないので、
    /// 「担当 PC あり × owner」…「担当 PC なし × owner」の 1 段の並びにする）。候補は絞らず（#115 Q4）、空のまとまりは返さない。
    /// 担当の印を確認できなかったときは、「担当 PC なし」と誤って見せないよう担当の有無では分けず、owner だけで分ける
    public static func grouping(_ repositories: [RequestRepository], now: Date) -> [Self] {
        guard repositories.allSatisfy(\.isAssignmentKnown) else {
            return byOwner(repositories.map(\.fullName), label: "担当 PC の有無を確認できませんでした")
        }
        let assigned = repositories.filter { $0.isAssigned(now: now) }.map(\.fullName)
        let others = repositories.filter { !$0.isAssigned(now: now) }.map(\.fullName)
        return byOwner(assigned, label: "担当 PC あり") + byOwner(others, label: "担当 PC なし")
    }

    /// owner（`owner/repo` の owner）ごとに分ける。見出しは owner 名で、`label` があれば「`label`・owner」にする。
    /// owner は 1 つだけでも見出しに出す（Discussion #572 Q2）。Section は owner が最初に出てきた順、Section の中は元の順に並べる。
    /// owner は大文字小文字を区別せずにまとめ、見出しには最初に出てきた表記を使う（ステータスタブの `LoopStatusOrganizationSection` と同じ）
    public static func byOwner(_ repositories: [String], label: String? = nil) -> [Self] {
        var owners: [String] = []
        var repositoriesByKey: [String: [String]] = [:]
        for repository in repositories {
            let owner = LoopStatusOrganizationSection.owner(of: repository)
            let key = owner.lowercased()
            if repositoriesByKey[key] == nil {
                owners.append(owner)
            }
            repositoriesByKey[key, default: []].append(repository)
        }
        return owners.map { owner in
            Self(
                title: label.map { "\($0)・\(owner)" } ?? owner,
                repositories: repositoriesByKey[owner.lowercased()] ?? []
            )
        }
    }
}
