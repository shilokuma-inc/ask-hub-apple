@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 「対象に加える」の候補（`RepositoryCandidatesWatch`）を、毎日のトークンで持ち主ごとに読んで書く
struct RepositoryCandidatesWatchTests {
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let stateRepository = RepositoryFullName(rawValue: "shilokuma-inc/askhub-state")!

    func watch(
        _ store: InMemoryStateStore,
        transport: StubTransport,
        owners: [String] = ["shilokuma-inc"],
        now: Date = Self.now
    ) -> RepositoryCandidatesWatch {
        RepositoryCandidatesWatch(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { now },
            owners: { owners },
            listing: { GitHubOwnerRepositories(owner: $0, transport: transport) { _ in "github_pat_daily" } },
            stateRepository: Self.stateRepository,
            log: { _ in }
        )
    }

    func candidates(in store: InMemoryStateStore) async throws -> RepositoryCandidatesFile? {
        try await store.data(at: StatePath.repositoryCandidates).map { try StateFileCoder.decode(RepositoryCandidatesFile.self, from: $0) }
    }

    static func repository(_ name: String, owner: String = "shilokuma-inc", isPrivate: Bool = false, extra: String = "") -> String {
        #"{"name":"\#(name)","owner":{"login":"\#(owner)"},"private":\#(isPrivate),"pushed_at":"2026-11-20T08:00:00Z"\#(extra)}"#
    }

    /// organization は `orgs/<org>/repos` を読み、アーカイブ・テンプレート・状態リポジトリを除いて名前の順に書く。
    /// 同じ中身なら書き直さない
    @Test func writesOrganizationRepositoriesOnlyWhenChanged() async throws {
        let store = InMemoryStateStore()
        let page = "[" + [
            Self.repository("zeta-ios", extra: #","description":"説明\n2 行目""#),
            Self.repository("askhub-state", isPrivate: true),
            Self.repository("old-ios", extra: #","archived":true"#),
            Self.repository("template-app-ios", extra: #","is_template":true"#),
            Self.repository("alpha-ios", isPrivate: true)
        ].joined(separator: ",") + "]"
        let transport = StubTransport([
            .json(200, #"{"type":"Organization"}"#),
            .json(200, page),
            .json(200, #"{"type":"Organization"}"#),
            .json(200, page)
        ])
        let watch = watch(store, transport: transport)
        #expect(try await watch.refresh())
        let file = try #require(try await candidates(in: store))
        let owner = try #require(file.owners.first)
        #expect(owner.owner == "shilokuma-inc")
        #expect(owner.readAt == Timestamp(Self.now))
        #expect(owner.problem == nil)
        #expect(owner.repositories.map(\.name) == ["alpha-ios", "zeta-ios"])
        #expect(owner.repositories.first?.isPrivate == true)
        #expect(owner.repositories.last?.description == "説明 2 行目")
        // 2 回目は同じ中身なので書かない
        #expect(try await !watch.refresh())
        // 読むだけで、毎日のトークンを使う
        #expect(transport.requests.allSatisfy { request in
            request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_daily"
        })
        #expect(transport.requests[1].url?.path == "/orgs/shilokuma-inc/repos")
    }

    /// 個人は、自分の（トークンの）リポジトリと public のリポジトリを合わせる
    @Test func mergesOwnAndPublicRepositoriesForUser() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([
            .json(200, #"{"type":"User"}"#),
            .json(200, "[" + Self.repository("private-ios", owner: "mrs1669", isPrivate: true) + "]"),
            .json(200, "[" + Self.repository("private-ios", owner: "mrs1669") + "," + Self.repository("public-ios", owner: "mrs1669") + "]")
        ])
        let watch = watch(store, transport: transport, owners: ["mrs1669"])
        #expect(try await watch.refresh())
        let owner = try #require(try await candidates(in: store)?.owners.first)
        #expect(owner.repositories.map(\.name) == ["private-ios", "public-ios"])
        #expect(owner.repositories.first?.isPrivate == true)
        #expect(transport.requests.map { $0.url?.path } == ["/users/mrs1669", "/user/repos", "/users/mrs1669/repos"])
    }

    /// 読めなかったら、前に読めた一覧を残して理由を書く。上限に当たったら、残りの持ち主は読まずに前のまま
    @Test func keepsPreviousListWhenReadingFails() async throws {
        let store = InMemoryStateStore()
        let hourAgo = Timestamp(Self.now.addingTimeInterval(-3600))
        let previous = RepositoryCandidatesFile(owners: [
            .init(owner: "shilokuma-inc", readAt: hourAgo, repositories: [.init(name: "alpha-ios", isPrivate: false)]),
            .init(owner: "mrs1669", readAt: hourAgo, repositories: [.init(name: "beta-ios", isPrivate: false)])
        ])
        await store.put(StatePath.repositoryCandidates, data: try StateFileCoder.encode(previous))
        let transport = StubTransport([
            .json(403, #"{"message":"API rate limit exceeded"}"#, headers: ["x-ratelimit-remaining": "0", "retry-after": "60"])
        ])
        let watch = watch(store, transport: transport, owners: ["shilokuma-inc", "mrs1669"])
        #expect(try await watch.refresh())
        let file = try #require(try await candidates(in: store))
        #expect(file.owners.map(\.repositories) == previous.owners.map(\.repositories))
        #expect(file.owners.first?.readAt == previous.owners.first?.readAt)
        #expect(file.owners.first?.problem?.contains("上限") == true)
        // 上限に当たった後の持ち主は読まずに、前のまま
        #expect(file.owners.last == previous.owners.last)
        #expect(transport.requests.count == 1)
    }

    /// 毎日のトークンが無ければ、理由を書く
    @Test func reportsMissingDailyToken() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([])
        let watch = RepositoryCandidatesWatch(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now },
            owners: { ["shilokuma-inc"] },
            listing: { GitHubOwnerRepositories(owner: $0, transport: transport) { _ in throw StateStoreError.tokenUnavailable } },
            stateRepository: Self.stateRepository,
            log: { _ in }
        )
        #expect(try await watch.refresh())
        let owner = try #require(try await candidates(in: store)?.owners.first)
        #expect(owner.repositories.isEmpty)
        #expect(owner.readAt == nil)
        #expect(owner.problem?.contains("askhub-commander token shilokuma-inc") == true)
    }

    /// 説明は 1 行にそろえ、上限で切る
    @Test func trimsLongDescription() {
        let long = String(repeating: "あ", count: 300)
        let trimmed = RepositoryCandidatesWatch.description(long)
        #expect(trimmed?.unicodeScalars.count == RepositoryCandidatesFile.maximumDescriptionLength)
        #expect(trimmed?.hasSuffix("…") == true)
        #expect(RepositoryCandidatesWatch.description(" \n ") == nil)
    }
}
