@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 新しいアプリを App Store に載せる準備: チェックリストを出し、「あなたの番」に出し、操作を送る
extension StateClientServiceTests {
    private static let setupPath = "repos/\(repo)/app-store.json"

    /// アプリがまだ無いリポジトリ
    static func missingAppFiles(extra: [String: String] = [:]) -> [String: String] {
        let setup = """
            {"v":1,"repo":"\(repo)","bundleIds":["jp.example.Sample","jp.example.SampleTests"],"app":null,
             "items":[{"id":"bundleId","state":"unknown","note":"鍵で Bundle ID を読めない","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"app","state":"todo","checkedAt":"2027-01-20T01:00:00Z"}],
             "checkedAt":"2027-01-20T01:00:00Z","createdAt":"2027-01-20T01:00:00Z","updatedAt":"2027-01-20T01:00:00Z"}
            """
        return askingEpic(extra: [setupPath: setup].merging(extra) { $1 })
    }

    /// アプリはあり、初めての版の項目が残っている
    static func firstReleaseFiles(extra: [String: String] = [:]) -> [String: String] {
        let setup = """
            {"v":1,"repo":"\(repo)","bundleIds":["jp.example.Sample"],
             "app":{"id":"6740000002","name":"サンプル","bundleId":"jp.example.Sample","primaryLocale":"ja"},
             "items":[{"id":"bundleId","state":"done","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"app","state":"done","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"contentRights","state":"done","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"category","state":"todo","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"price","state":"todo","checkedAt":"2027-01-20T01:00:00Z"},
                      {"id":"appPrivacy","state":"unknown","checkedAt":"2027-01-20T01:00:00Z"}],
             "checkedAt":"2027-01-20T01:00:00Z","createdAt":"2027-01-20T01:00:00Z","updatedAt":"2027-01-20T01:00:00Z"}
            """
        return askingEpic(extra: [setupPath: setup].merging(extra) { $1 })
    }

    private var setupRepositoryID: TargetRepository.ID { Self.repo.lowercased() }

    @Test
    func showsCreateAppWhenAppIsMissing() async throws {
        let fixture = try makeService(files: Self.missingAppFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let setup = try #require(snapshot.appStoreSetup(of: setupRepositoryID))
        #expect(setup.mainBundleID == "jp.example.Sample")
        #expect(setup.pendingItems(firstRelease: false).map(\.kind) == [.bundleId, .app])
        let items = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .appStoreSetup }
        #expect(items.map(\.title) == ["App Store Connect でアプリを作る"])
        #expect(items.first?.route == .appStoreSetup(setupRepositoryID))
        // アプリが無いうちは、決まった値を書けない。確かめていない項目は「終わった」にできない
        #expect(!fixture.service.supports(.applyAppStoreSettings(repositoryID: setupRepositoryID, request: .init(free: true))))
        #expect(!fixture.service.supports(.confirmAppStoreItem(repositoryID: setupRepositoryID, item: .appPrivacy)))
        #expect(fixture.service.supports(.confirmAppStoreItem(repositoryID: setupRepositoryID, item: .bundleId)))
        #expect(!fixture.service.supports(.confirmAppStoreItem(repositoryID: setupRepositoryID, item: .app)))
    }

    @Test
    func registersMainBundleIDOnly() async throws {
        let fixture = try makeService(files: Self.missingAppFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        #expect(!service.supports(.registerBundleId(repositoryID: setupRepositoryID, identifier: "jp.example.Other", platform: .iOS)))
        let intent = HumanIntent.registerBundleId(repositoryID: setupRepositoryID, identifier: "jp.example.Sample", platform: .universal)
        #expect(service.supports(intent))
        try await service.perform(intent)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == RegisterBundleIdIntent.kind)
        #expect(envelope.payload == ["identifier": .string("jp.example.Sample"), "platform": .string("universal")])
        #expect(envelope.target == nil)

        // 送った後は書き込みの途中として出し、次の登録は送れない
        let sent = try await service.fetchSnapshot()
        #expect(sent.appStoreSetup(of: setupRepositoryID)?.isWriting == true)
        #expect(!service.supports(intent))
        #expect(sent.sentIntents.first?.title == "Bundle ID の登録（jp.example.Sample）")
        #expect(sent.sentIntents.first?.target == .appStore(setupRepositoryID))
    }

    @Test
    func showsRemainingItemsOnlyAfterFirstReleaseStarts() async throws {
        let fixture = try makeService(files: Self.firstReleaseFiles())
        let before = try await fixture.service.fetchSnapshot()
        // リリースを始めるまでは、あなたの番に出さない（画面からは見られる）
        #expect(!InboxBuilder.items(from: before, now: now).contains { $0.kind == .appStoreSetup })
        #expect(before.appStoreSetup(of: setupRepositoryID)?.writableItems.map(\.kind) == [.category, .price])

        let key = String(repeating: "k", count: 43)
        let start = """
            {"v":1,"repo":"\(Self.repo)","version":"1.0.0","origin":"askhub",
             "start":{"approval":{"keyId":"\(key)","nonce":"01JCN0NCE00000000000000009"},"at":"2027-01-20T01:00:00Z"},
             "builds":[],"revision":0,"review":[],"appStoreVersions":[],
             "createdAt":"2027-01-20T01:00:00Z","updatedAt":"2027-01-20T01:00:00Z"}
            """
        let started = try makeService(files: Self.firstReleaseFiles(extra: ["repos/\(Self.repo)/submissions/1.0.0.json": start]))
        let snapshot = try await started.service.fetchSnapshot()
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .appStoreSetup })
        #expect(item.title == "App Store の準備を終える")
        #expect(item.detail.contains("残り 3 個"))
    }

    @Test
    func writesChosenSettingsAndConfirmsWebItems() async throws {
        let fixture = try makeService(files: Self.firstReleaseFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let games = AppStoreCategoryChoice.all.first { $0.subcategory == "GAMES_PUZZLE" }
        let request = AppStoreSettingsRequest(category: games, privacyPolicyURL: " https://example.com/privacy ", free: true)
        try await service.perform(.applyAppStoreSettings(repositoryID: setupRepositoryID, request: request))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let apply = try ApplyAppStoreSettingsIntent(envelope: envelope)
        #expect(apply.settings == AppStoreSettings(
            primaryCategory: "GAMES",
            primarySubcategory: "GAMES_PUZZLE",
            privacyPolicyUrl: "https://example.com/privacy",
            price: .free
        ))
        // http の URL は送らない
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.applyAppStoreSettings(
                repositoryID: setupRepositoryID,
                request: .init(privacyPolicyURL: "http://example.com")
            ))
        }
    }

    @Test
    func confirmationAndExclusionAreShownBeforeTheCommanderReadsThem() async throws {
        let fixture = try makeService(files: Self.firstReleaseFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.confirmAppStoreItem(repositoryID: setupRepositoryID, item: .appPrivacy))
        var snapshot = try await service.fetchSnapshot()
        #expect(snapshot.appStoreSetup(of: setupRepositoryID)?.item(.appPrivacy)?.isDone == true)
        #expect(!service.supports(.confirmAppStoreItem(repositoryID: setupRepositoryID, item: .appPrivacy)))

        #expect(!service.supports(.excludeFromAppStore(repositoryID: setupRepositoryID, excluded: false)))
        try await service.perform(.excludeFromAppStore(repositoryID: setupRepositoryID, excluded: true))
        snapshot = try await service.fetchSnapshot()
        #expect(snapshot.appStoreSetup(of: setupRepositoryID)?.isExcluded == true)
        #expect(snapshot.sentIntents.first?.title == "App Store に出さない（sample-ios）")
        #expect(service.supports(.excludeFromAppStore(repositoryID: setupRepositoryID, excluded: false)))
    }

    @Test
    func opensSetupFromPush() throws {
        let target = try #require(PushTarget(userInfo: ["askhub": ["repo": "Example/Sample-iOS", "appStore": "setup"]]))
        #expect(target == .appStore(repo: RepositoryFullName(rawValue: "Example/Sample-iOS")!))
        #expect(target.route == .appStoreSetup("example/sample-ios"))
        #expect(target.section == .repositories)
    }
}
