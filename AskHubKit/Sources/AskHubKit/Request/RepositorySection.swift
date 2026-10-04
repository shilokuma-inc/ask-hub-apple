/// 依頼先の Picker に出すリポジトリのまとまり（Discussion #115 Q5: Picker のまま Section で分ける）
public struct RepositorySection: Equatable, Sendable, Identifiable {
    public let title: String
    /// `owner/repo`。元の一覧の順（最近 push された順）を保つ
    public let repositories: [String]

    public var id: String { title }

    public init(title: String, repositories: [String]) {
        self.title = title
        self.repositories = repositories
    }

    /// アプリのリポジトリ（名前が `-ios` / `-apple` で終わる）とそれ以外に分ける。
    /// 候補は絞らず、空のまとまりは返さない
    public static func grouping(_ repositories: [String]) -> [Self] {
        let apps = repositories.filter(isApp)
        let others = repositories.filter { !isApp($0) }
        return [
            Self(title: "アプリ", repositories: apps),
            Self(title: "その他", repositories: others)
        ]
        .filter { !$0.repositories.isEmpty }
    }

    private static func isApp(_ repository: String) -> Bool {
        let name = (repository.split(separator: "/").last.map(String.init) ?? repository).lowercased()
        return name.hasSuffix("-ios") || name.hasSuffix("-apple")
    }
}
