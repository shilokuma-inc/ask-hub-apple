import Foundation

/// `repo-candidates.json`（「対象に加える」の候補）。司令塔だけが書く。
///
/// 司令塔が、毎日のトークンを置いた持ち主ごとに、そのトークンで読めるリポジトリの一覧を読んで書く
/// （`docs/renewal/operations.md` の「対象のリポジトリ」）。クライアントのトークンは状態リポジトリしか読めないので、候補はこのファイルから出す。
/// 対象かどうかは書かない（クライアントが `repos/` と照らし合わせて、まだ対象でないものだけを出す）
public struct RepositoryCandidatesFile: StateFile {
    public static let formatVersion = 1
    /// 1 つの持ち主のリポジトリの数の上限（多ければ、最近 push したものから残す）
    public static let maximumRepositories = 1000
    /// 説明の長さの上限（Unicode のコードポイントの数。長ければ切る）
    public static let maximumDescriptionLength = 200

    public struct Repository: Codable, Equatable, Sendable {
        /// リポジトリの名前（持ち主を除く。GitHub の `name` のまま）
        public var name: String
        public var isPrivate: Bool
        public var description: String?
        /// 最後に push された時刻。無ければ nil
        public var pushedAt: Timestamp?

        public init(name: String, isPrivate: Bool, description: String? = nil, pushedAt: Timestamp? = nil) {
            self.name = name
            self.isPrivate = isPrivate
            self.description = description
            self.pushedAt = pushedAt
        }
    }

    public struct Owner: Codable, Equatable, Sendable {
        /// 持ち主（organization・個人）。毎日のトークンを置いた持ち主の書き方のまま（小文字）
        public var owner: String
        /// 一覧を読んだ時刻（中身が変わったときだけ書き直す）。まだ読めていなければ nil
        public var readAt: Timestamp?
        /// 読めたリポジトリ。アーカイブ・テンプレート・状態リポジトリは入れない。名前の順
        public var repositories: [Repository]
        /// 最後に読もうとして読めなかった理由。読めたら nil（読めなかったときは、前に読めた一覧を残す）
        public var problem: String?

        public init(owner: String, readAt: Timestamp? = nil, repositories: [Repository] = [], problem: String? = nil) {
            self.owner = owner
            self.readAt = readAt
            self.repositories = repositories
            self.problem = problem
        }

        /// リポジトリの `owner/name`
        public func fullName(of repository: Repository) -> RepositoryFullName? {
            RepositoryFullName(rawValue: "\(owner)/\(repository.name)")
        }
    }

    /// 持ち主ごとの一覧（毎日のトークンを置いた持ち主の順）
    public var owners: [Owner]

    public init(owners: [Owner] = []) {
        self.owners = owners
    }

    public var violations: [String] {
        var violations: [String] = []
        let names = owners.map { $0.owner.lowercased() }
        if Set(names).count != names.count { violations.append("owners の持ち主が重なっている") }
        for owner in owners {
            if RepositoryFullName(rawValue: "\(owner.owner)/x") == nil { violations.append("\(owner.owner) は持ち主の名前の形でない") }
            if owner.repositories.count > Self.maximumRepositories {
                violations.append("\(owner.owner) のリポジトリが \(Self.maximumRepositories) を超える")
            }
            let repositories = owner.repositories.map { $0.name.lowercased() }
            if Set(repositories).count != repositories.count { violations.append("\(owner.owner) のリポジトリが重なっている") }
            if owner.repositories.contains(where: { owner.fullName(of: $0) == nil }) {
                violations.append("\(owner.owner) にリポジトリの名前の形でないものがある")
            }
            if owner.repositories.contains(where: { ($0.description?.unicodeScalars.count ?? 0) > Self.maximumDescriptionLength }) {
                violations.append("\(owner.owner) のリポジトリの説明が \(Self.maximumDescriptionLength) 文字を超える")
            }
        }
        return violations
    }
}
