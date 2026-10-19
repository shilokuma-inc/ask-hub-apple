import Foundation

/// 「実機確認」「任意判断」の一覧の並び順（Discussion #586 の Q3）。
///
/// 取得済みの一覧を View の側で並べ直すだけで、取得処理（`InboxFetcher.lowPriorityIssues`）の並びは変えない
public enum InboxIssueSortOrder: String, Sendable, CaseIterable, Identifiable {
    /// 更新日の新しい順（既定。`InboxFetcher.lowPriorityIssues` の並びと同じ）
    case updatedNewest
    /// 更新日の古い順
    case updatedOldest
    /// 作成日の新しい順
    case createdNewest
    /// 作成日の古い順
    case createdOldest

    /// 既定の並び順。今までの一覧と同じ並びになる
    public static let `default` = Self.updatedNewest

    public var id: Self { self }

    /// メニューに出す文言
    public var title: String {
        switch self {
        case .updatedNewest: "更新日（新しい順）"
        case .updatedOldest: "更新日（古い順）"
        case .createdNewest: "作成日（新しい順）"
        case .createdOldest: "作成日（古い順）"
        }
    }

    /// `issues` をこの順に並べる。
    ///
    /// 同じ日時のときは、新しい順では `id` の降順、古い順では `id` の昇順にする
    /// （古い順は新しい順をちょうど逆にした並び。取り直しても同じ順になる）
    public func sorted(_ issues: [InboxIssue]) -> [InboxIssue] {
        switch self {
        case .updatedNewest: issues.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        case .updatedOldest: issues.sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
        case .createdNewest: issues.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        case .createdOldest: issues.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        }
    }
}

/// 「実機確認」「任意判断」の一覧の絞り込みの候補になるリポジトリ（Discussion #586 の Q1）
public struct InboxRepositoryOption: Sendable, Equatable, Hashable, Identifiable {
    /// `owner/repo`（`InboxIssue.repository`）
    public var repository: String
    /// 絞り込む前の一覧（そのタブの全件）にある、このリポジトリの Issue の件数
    public var count: Int
    /// メニューに出す名前。owner を省いた名前で、同じ名前のリポジトリが別の owner にあるときだけ `owner/repo`
    public var displayName: String

    public var id: String { repository }

    public init(repository: String, count: Int, displayName: String) {
        self.repository = repository
        self.count = count
        self.displayName = displayName
    }

    /// `issues`（1 つのタブの一覧）にあるリポジトリと件数の候補を、`displayName` の順（大文字小文字を区別しない）に返す。
    ///
    /// リポジトリは `owner/repo` で区別し、別の owner の同じ名前のリポジトリは混ぜない
    public static func options(in issues: [InboxIssue]) -> [Self] {
        var counts: [String: Int] = [:]
        for issue in issues {
            counts[issue.repository, default: 0] += 1
        }
        var shortNameCounts: [String: Int] = [:]
        for repository in counts.keys {
            shortNameCounts[shortName(of: repository).lowercased(), default: 0] += 1
        }
        return counts
            .map { repository, count in
                let short = shortName(of: repository)
                let isAmbiguous = shortNameCounts[short.lowercased(), default: 0] > 1
                return Self(repository: repository, count: count, displayName: isAmbiguous ? repository : short)
            }
            .sorted {
                let order = $0.displayName.caseInsensitiveCompare($1.displayName)
                return order == .orderedSame ? $0.repository < $1.repository : order == .orderedAscending
            }
    }

    /// `owner/repo` から owner を省いた名前
    private static func shortName(of repository: String) -> String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

/// 「実機確認」「任意判断」の一覧の、リポジトリでの絞り込み（Discussion #586 の Q1）。
///
/// 選んだ値は保存しない（再起動後は「すべて」に戻る）
public enum InboxRepositoryFilter: Sendable, Equatable, Hashable {
    /// 絞り込まない
    case all
    /// `owner/repo` のリポジトリの Issue だけを出す
    case repository(String)

    /// `issues` をこの条件で絞り込む。並びは変えない
    public func filtered(_ issues: [InboxIssue]) -> [InboxIssue] {
        switch self {
        case .all: issues
        case let .repository(repository): issues.filter { $0.repository == repository }
        }
    }

    /// 絞り込み中のリポジトリが `issues` に無くなったら（すべて閉じた・取り直したら無くなったなど）`.all` を返す
    public func resolved(in issues: [InboxIssue]) -> Self {
        switch self {
        case .all:
            .all
        case let .repository(repository):
            issues.contains { $0.repository == repository } ? self : .all
        }
    }
}

extension Array where Element == InboxIssue {
    /// 一覧に出す並びにする: `filter` で絞り込み、`order` で並べる
    public func arranged(filter: InboxRepositoryFilter, order: InboxIssueSortOrder) -> [InboxIssue] {
        order.sorted(filter.filtered(self))
    }
}
