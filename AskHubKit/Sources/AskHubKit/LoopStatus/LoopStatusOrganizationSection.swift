import Foundation

/// ステータスタブの「リポジトリ」の一覧で、organization（`owner/repo` の owner）ごとにまとめた節 1 つ分
public struct LoopStatusOrganizationSection: Sendable, Equatable, Identifiable {
    /// 見出しに出す organization の login（節の最初の行の owner をそのまま使う）
    public var organization: String
    /// 節の行（元の並びのまま）
    public var rows: [LoopStatusRow]

    public init(organization: String, rows: [LoopStatusRow]) {
        self.organization = organization
        self.rows = rows
    }

    /// GitHub の login は大文字小文字を区別しないので、小文字で見分ける
    public var id: String {
        organization.lowercased()
    }

    /// 行を owner ごとの節にまとめる。節は owner が最初に出てきた順、節の中の行は元の順に並べる。
    /// owner は大文字小文字を区別せずにまとめる（`Shilokuma-Inc/a` と `shilokuma-inc/b` は同じ節）
    public static func sections(from rows: [LoopStatusRow]) -> [Self] {
        var sections: [Self] = []
        var indexByKey: [String: Int] = [:]
        for row in rows {
            let owner = owner(of: row.repository)
            let key = owner.lowercased()
            if let index = indexByKey[key] {
                sections[index].rows.append(row)
            } else {
                indexByKey[key] = sections.count
                sections.append(Self(organization: owner, rows: [row]))
            }
        }
        return sections
    }

    /// `owner/repo` の owner。`/` が無ければ全体を返す
    static func owner(of repository: String) -> String {
        repository.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? repository
    }
}
