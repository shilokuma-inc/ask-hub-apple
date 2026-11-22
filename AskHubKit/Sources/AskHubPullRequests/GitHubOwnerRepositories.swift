import AskHubProtocol
import AskHubStateStore
import Foundation

/// 持ち主（organization・個人）のリポジトリの一覧を読む。司令塔が「対象に加える」の候補（`repo-candidates.json`）を書くのに使う。
///
/// 自動で読むので、毎日のトークン（Metadata の読み取り）で読むだけにする。fine-grained token では、public のリポジトリと、
/// トークンの Repository access に入れた private のリポジトリが返る（入れていない private のものは、どのみちワーカーが扱えない）
public struct GitHubOwnerRepositories: Sendable {
    public let owner: String
    let api: GitHubAPI

    /// `token` は持ち主を受け取り、その持ち主の fine-grained token を返す。持ち主の名前の形でなければ nil
    public init?(
        owner: String,
        apiBase: URL = URL(string: "https://api.github.com")!,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable (_ owner: String) async throws -> String
    ) {
        // `GitHubAPI` はリポジトリの持ち主でトークンを選ぶ。ここでは持ち主のトークンを選ぶためだけに使い、URL には使わない
        guard let tokenOwner = RepositoryFullName(rawValue: "\(owner)/.github") else { return nil }
        self.owner = owner
        api = GitHubAPI(repository: tokenOwner, apiBase: apiBase, transport: transport, now: now, token: token)
    }

    /// 持ち主のリポジトリ。organization なら `orgs/<org>/repos`、個人なら自分の（トークンの）リポジトリと public のリポジトリを合わせる
    public func repositories() async throws(PullRequestError) -> [OwnerRepository] {
        let account = try await api.get(absolute: api.rootURL("users/\(owner)"), what: "users", as: AccountPayload.self)
        var found: [OwnerRepository] = []
        if account.type == "Organization" {
            found = try await list("orgs/\(owner)/repos", query: [.init(name: "type", value: "all")])
        } else {
            // 個人のトークンは、その個人を持ち主にして作る。`user/repos` は private も返すが、public を返すかは
            // トークンの Repository access によるので、`users/<owner>/repos`（public だけ）も合わせる
            let own = try await list("user/repos", query: [.init(name: "affiliation", value: "owner")])
            let shown = try await list("users/\(owner)/repos", query: [.init(name: "type", value: "owner")])
            found = own + shown.filter { repository in !own.contains { $0.name.lowercased() == repository.name.lowercased() } }
        }
        return found.filter { $0.owner.lowercased() == owner.lowercased() }
    }

    private func list(_ path: String, query: [URLQueryItem]) async throws(PullRequestError) -> [OwnerRepository] {
        let start = try api.rootURL(path, query: query + [.init(name: "per_page", value: "100")])
        return try await api.pages(from: start, what: path, as: [OwnerRepositoryPayload].self).flatMap { $0.map(\.repository) }
    }
}

/// 持ち主のリポジトリ（一覧の 1 つ）
public struct OwnerRepository: Equatable, Sendable {
    public var owner: String
    public var name: String
    public var isPrivate: Bool
    public var isArchived: Bool
    public var isTemplate: Bool
    public var description: String?
    public var pushedAt: Date?

    public init(
        owner: String,
        name: String,
        isPrivate: Bool,
        isArchived: Bool = false,
        isTemplate: Bool = false,
        description: String? = nil,
        pushedAt: Date? = nil
    ) {
        self.owner = owner
        self.name = name
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.isTemplate = isTemplate
        self.description = description
        self.pushedAt = pushedAt
    }
}

extension GitHubAPI {
    /// `url`（`rootURL` で作ったもの）を読む
    func get<Value: Decodable>(absolute url: URL, what: String, as type: Value.Type) async throws(PullRequestError) -> Value {
        let (data, _) = try await send("GET", url)
        return try Self.decode(type, from: data, what: what)
    }
}

// MARK: - 応答の形

private struct AccountPayload: Decodable {
    let type: String
}

private struct OwnerRepositoryPayload: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let owner: Owner
    let `private`: Bool
    let archived: Bool?
    let isTemplate: Bool?
    let description: String?
    let pushedAt: Date?

    var repository: OwnerRepository {
        OwnerRepository(
            owner: owner.login,
            name: name,
            isPrivate: `private`,
            isArchived: archived ?? false,
            isTemplate: isTemplate ?? false,
            description: description,
            pushedAt: pushedAt
        )
    }
}
