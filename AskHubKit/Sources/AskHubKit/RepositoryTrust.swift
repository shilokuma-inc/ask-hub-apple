import Foundation

/// リポジトリごとの信用する author を返す。
///
/// 信用する author は、設定の一覧（`TrustedAuthors`）に、そのリポジトリに書き込み権限（write 以上）を持つアカウントを加えたもの。
/// ラベルの付け外しやマージには、どのみち write 権限が要るので、「権限がある人 = 指示として扱ってよい人」とそろえる。
/// 詳細は `docs/protocol.md` の「信用する author」を参照
public protocol TrustedAuthorsResolving: Sendable {
    /// `repository`（`owner/repo`）で、指示として扱ってよい author
    func trustedAuthors(for repository: String) async -> TrustedAuthors
}

extension TrustedAuthors: TrustedAuthorsResolving {
    /// 固定の一覧。どのリポジトリでも同じ
    public func trustedAuthors(for repository: String) async -> TrustedAuthors {
        self
    }
}

/// リポジトリに書き込み権限（write・maintain・admin）を持つアカウントの取得元。テストでは差し替える
public protocol RepositoryWritersSource: Sendable {
    /// `repository`（`owner/repo`）に書き込み権限を持つアカウントの login
    func writers(of repository: String) async throws -> [String]
}

/// GitHub の REST API（`repos/{owner}/{repo}/collaborators`）から、書き込み権限を持つアカウントを取得する。
///
/// collaborator の一覧には、直接招待した人のほか、チーム・organization の既定の権限・organization の owner も含まれる（`affiliation=all`）。
/// この API はトークンの持ち主に push 権限が要る。権限が無ければ失敗し、呼び出し側は設定の一覧だけを使う
public struct GitHubRepositoryWriters: RepositoryWritersSource {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func writers(of repository: String) async throws -> [String] {
        try await client.getAllPages(
            "repos/\(repository)/collaborators",
            query: [URLQueryItem(name: "affiliation", value: "all")],
            of: RepositoryCollaborator.self
        )
        .filter(\.canWrite)
        .map(\.login)
    }
}

/// `repos/{owner}/{repo}/collaborators` の 1 件
private struct RepositoryCollaborator: Decodable {
    struct Permissions: Decodable {
        let admin: Bool?
        let maintain: Bool?
        let push: Bool?
    }

    let login: String
    let permissions: Permissions?

    var canWrite: Bool {
        permissions?.push == true || permissions?.maintain == true || permissions?.admin == true
    }
}

/// リポジトリごとの書き込み権限を持つアカウントを、一定時間覚えておく。
///
/// ポーリングや一覧の取得のたびに API を呼ばないよう、`lifetime` の間は前回の結果を使う。
/// 取得に失敗したときは、前回の結果があればそれを使い、無ければ `nil`（設定の一覧だけを信用する）を返す。
/// 失敗も覚えて、`lifetime` の間は取り直さない（権限の無いリポジトリで毎回失敗しないため）
public actor RepositoryWriters {
    /// 結果を使い回す時間の既定値
    public static let defaultLifetime: Duration = .seconds(10 * 60)

    private struct Entry {
        /// 最後に取得できた一覧。一度も取得できていなければ `nil`
        var writers: TrustedAuthors?
        var checkedAt: Date
    }

    private let source: any RepositoryWritersSource
    private let lifetime: Duration
    private let now: @Sendable () -> Date
    /// キーは `owner/repo` を小文字にしたもの
    private var entries: [String: Entry] = [:]

    public init(
        source: any RepositoryWritersSource,
        lifetime: Duration = defaultLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.lifetime = lifetime
        self.now = now
    }

    /// 書き込み権限を持つアカウント。取得できなければ `nil`
    public func writers(of repository: String) async -> TrustedAuthors? {
        let key = repository.lowercased()
        let current = now()
        if let entry = entries[key], current.timeIntervalSince(entry.checkedAt) < TimeInterval(lifetime.components.seconds) {
            return entry.writers
        }
        do {
            let writers = TrustedAuthors(try await source.writers(of: repository))
            entries[key] = Entry(writers: writers, checkedAt: current)
            return writers
        } catch {
            let previous = entries[key]?.writers
            entries[key] = Entry(writers: previous, checkedAt: current)
            return previous
        }
    }
}

/// 設定の一覧に、リポジトリの書き込み権限を持つアカウントを加えて信用する
public struct RepositoryTrust: TrustedAuthorsResolving {
    /// どのリポジトリでも信用する author（設定の一覧）
    public let base: TrustedAuthors
    private let writers: RepositoryWriters

    public init(base: TrustedAuthors, writers: RepositoryWriters) {
        self.base = base
        self.writers = writers
    }

    public func trustedAuthors(for repository: String) async -> TrustedAuthors {
        guard let writers = await writers.writers(of: repository) else {
            return base
        }
        return base.union(writers)
    }
}
