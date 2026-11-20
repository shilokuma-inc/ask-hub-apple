@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 新しいアプリを App Store に載せる準備: 人の意図の処理と、見回りの確かめ・書き込み・通知
struct AppStoreSetupTests {
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let path = StatePath.appStoreSetup(ReleaseWatchTests.repo)
    let base = ReleaseWatchTests()

    var context: CommanderContext {
        CommanderContext(store: base.store, mac: MacName(rawValue: "mac-mini")!) { ReleaseWatchTests.now }
    }

    func envelope(_ kind: String, _ payload: [String: JSONValue], nonce: String = "01JCN0NCE00000000000000001") -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: ReleaseWatchTests.repo,
            payload: payload,
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    func setup() async throws -> AppStoreSetupFile? {
        guard let data = await base.store.data(at: Self.path) else { return nil }
        return try StateFileCoder.decode(AppStoreSetupFile.self, from: data)
    }

    func put(_ file: AppStoreSetupFile) async throws {
        await base.store.put(Self.path, data: try StateFileCoder.encode(file))
    }

    func app() {
        base.appStore.state.withLock { $0.apps = [AppStoreApp(id: "6740000002", bundleId: "jp.shilokuma.OshiCon", name: "推し活カウントダウン")] }
    }

    func items(_ file: AppStoreSetupFile?) -> [AppStoreSetupFile.ItemKind: AppStoreSetupFile.ItemState] {
        Dictionary((file?.items ?? []).map { ($0.id, $0.state) }) { first, _ in first }
    }

    // MARK: - 見回り

    @Test func checksBundleIDAndAppWhenAppIsMissing() async throws {
        try await base.addRepository()
        base.sources.state.withLock { $0.bundleIDs = ["jp.shilokuma.OshiCon", "jp.shilokuma.OshiConTests"] }
        base.appStore.state.withLock { $0.bundleIDs = ["jp.shilokuma.OshiCon"] }
        let watch = base.watch()
        await watch.refresh()
        let file = try #require(try await setup())
        #expect(file.app == nil)
        #expect(file.bundleIds == ["jp.shilokuma.OshiCon", "jp.shilokuma.OshiConTests"])
        #expect(file.items.map(\.id) == [.bundleId, .app])
        #expect(items(file) == [.bundleId: .done, .app: .todo])
        #expect(file.item(.app)?.note?.contains("jp.shilokuma.OshiCon") == true)
        let blockers = await watch.blockers
        #expect(blockers.map(\.key) == ["appStore/shariverse/oshikatsu-countdown-ios/app"])
        #expect(blockers.first?.scope == .appStore(ReleaseWatchTests.repo))
    }

    @Test func leavesBundleIDUnknownWhenKeyCannotReadProvisioning() async throws {
        try await base.addRepository()
        base.appStore.state.withLock { $0.bundleIDRefusal = .unauthorized(status: 403) }
        await base.watch().refresh()
        let file = try #require(try await setup())
        #expect(items(file) == [.bundleId: .unknown, .app: .todo])
        #expect(file.item(.bundleId)?.note?.contains("Upload") == true)
    }

    @Test func checksEveryItemOfAppWithoutLiveVersionAndKeepsConfirmations() async throws {
        try await base.addRepository()
        app()
        base.appStore.state.withLock { state in
            state.setup = AppStoreSetupState(
                primaryLocale: "ja",
                contentRights: "DOES_NOT_USE_THIRD_PARTY_CONTENT",
                appInfoID: "info-1",
                infoLocalizations: [.init(id: "loc-ja", locale: "ja", privacyPolicyUrl: nil)],
                unansweredAgeRatings: ["advertising"],
                hasPrice: false,
                hasAvailability: true
            )
        }
        let watch = base.watch()
        await watch.refresh()
        var file = try #require(try await setup())
        #expect(file.app == .init(id: "6740000002", name: "推し活カウントダウン", bundleId: "jp.shilokuma.OshiCon", primaryLocale: "ja"))
        #expect(items(file) == [
            .bundleId: .done, .app: .done, .contentRights: .done, .category: .todo, .privacyPolicy: .todo, .price: .todo,
            .availability: .done, .ageRating: .todo, .appPrivacy: .unknown, .digitalServicesAct: .unknown
        ])
        // アプリはあるので「アプリを作る」は出さない。リリースを始めていないので、初めての版の残りも出さない
        #expect(await watch.blockers.isEmpty)

        // 人が App のプライバシーを「終わった」にした
        let confirm = envelope("confirmAppStoreItem", ["item": .string("appPrivacy")])
        #expect(try await ConfirmAppStoreItemHandler().handle(confirm, in: context) == .accept)
        base.clock.advance(minutes: 31)
        await watch.refresh()
        file = try #require(try await setup())
        #expect(file.item(.appPrivacy)?.confirmed != nil)
        #expect(!file.pendingItems(firstRelease: true).contains { $0.id == .appPrivacy })
    }

    @Test func marksReleasedWhenLiveVersionIsFound() async throws {
        try await base.addRepository()
        app()
        await base.watch().refresh()
        #expect(try await setup()?.releasedAt == nil)
        base.live()
        base.clock.advance(minutes: 31)
        await base.watch().refresh()
        let file = try #require(try await setup())
        #expect(file.releasedAt == Timestamp(base.clock.now))
        #expect(!file.isActive)
    }

    @Test func doesNotCreateRecordForAppAlreadyOnSale() async throws {
        try await base.addRepository()
        base.live()
        await base.watch().refresh()
        #expect(try await setup() == nil)
    }

    @Test func skipsExcludedRepository() async throws {
        try await base.addRepository()
        let exclude = envelope("excludeFromAppStore", ["excluded": .bool(true)])
        #expect(try await ExcludeFromAppStoreHandler().handle(exclude, in: context) == .accept)
        let watch = base.watch()
        await watch.refresh()
        let file = try #require(try await setup())
        #expect(file.isExcluded && file.items.isEmpty)
        #expect(await watch.blockers.isEmpty)
        // 出すに戻すと、次に読むときに確かめる
        let include = envelope("excludeFromAppStore", ["excluded": .bool(false)], nonce: "01JCN0NCE00000000000000002")
        #expect(try await ExcludeFromAppStoreHandler().handle(include, in: context) == .accept)
        base.clock.advance(minutes: 31)
        await watch.refresh()
        #expect(items(try await setup()) == [.bundleId: .todo, .app: .todo])
    }

    @Test func registersBundleIDThatHumanConfirmed() async throws {
        try await base.addRepository()
        let watch = base.watch()
        await watch.refresh()
        #expect(items(try await setup())[.bundleId] == .todo)
        let register = envelope("registerBundleId", ["identifier": .string("jp.shilokuma.OshiCon"), "platform": .string("iOS")])
        #expect(try await RegisterBundleIdHandler().handle(register, in: context) == .accept)
        await watch.refresh()
        let file = try #require(try await setup())
        #expect(file.bundleIdRequest?.doneAt != nil && file.bundleIdRequest?.failures == nil)
        #expect(base.appStore.state.withLock { $0.writes } == ["registerBundleID jp.shilokuma.OshiCon iOS AskHub jp shilokuma OshiCon"])
        // 送った後に確かめ直している
        #expect(file.item(.bundleId)?.state == .done)
    }

    @Test func appliesOnlyUnsetSettingsAndRecordsRefusals() async throws {
        try await base.addRepository()
        app()
        base.appStore.state.withLock { state in
            state.setup = AppStoreSetupState(
                primaryLocale: "ja",
                contentRights: "USES_THIRD_PARTY_CONTENT",
                appInfoID: "info-1",
                infoLocalizations: [
                    .init(id: "loc-ja", locale: "ja", privacyPolicyUrl: nil),
                    .init(id: "loc-en", locale: "en-US", privacyPolicyUrl: "https://example.com/en")
                ],
                unansweredAgeRatings: [],
                hasPrice: false,
                hasAvailability: false
            )
        }
        let watch = base.watch()
        await watch.refresh()
        let settings = AppStoreSettings(
            contentRights: .doesNotUseThirdPartyContent,
            primaryCategory: "PRODUCTIVITY",
            privacyPolicyUrl: "https://example.com/privacy",
            price: .free,
            availability: .allTerritories
        )
        let apply = envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(settings))
        #expect(try await ApplyAppStoreSettingsHandler().handle(apply, in: context) == .accept)
        await watch.refresh()
        let file = try #require(try await setup())
        // 人が App Store Connect で決めたコンテンツの権利と、英語のプライバシーポリシーの URL は上書きしない
        #expect(base.appStore.state.withLock { $0.writes } == [
            "setCategory info-1 PRODUCTIVITY -",
            "setPrivacyPolicyURL loc-ja https://example.com/privacy",
            "setFreePrice",
            "setAvailableEverywhere"
        ])
        #expect(file.settingsRequest?.doneAt != nil && file.settingsRequest?.failures == nil)
        #expect(items(file)[.category] == .done && items(file)[.price] == .done && items(file)[.privacyPolicy] == .done)

        // 断られた項目は理由を書き、通知する
        let games = ApplyAppStoreSettingsIntent.payload(.init(primaryCategory: "GAMES"))
        let again = envelope("applyAppStoreSettings", games, nonce: "01JCN0NCE00000000000000003")
        base.appStore.state.withLock { $0.setup.primaryCategory = nil }
        #expect(try await ApplyAppStoreSettingsHandler().handle(again, in: context) == .accept)
        base.appStore.state.withLock { $0.refusal = .refused(status: 409, detail: "サブカテゴリが要る") }
        await watch.refresh()
        let refused = try #require(try await setup())
        #expect(refused.settingsRequest?.failures?.map(\.item) == [.category])
        #expect(refused.settingsRequest?.failures?.first?.message.contains("サブカテゴリが要る") == true)
        #expect(await watch.blockers.contains { $0.reason == .appStoreRefused([.category]) })
    }

    @Test func remindsRemainingItemsWhenFirstReleaseStarts() async throws {
        try await base.addRepository()
        app()
        let start = SubmissionFile(
            repo: ReleaseWatchTests.repo,
            version: MarketingVersion(rawValue: "1.0.0")!,
            origin: .askhub,
            start: .init(
                approval: IntentReference(keyId: Self.keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000009")!),
                at: Timestamp(ReleaseWatchTests.now)
            ),
            createdAt: Timestamp(ReleaseWatchTests.now),
            updatedAt: Timestamp(ReleaseWatchTests.now)
        )
        await base.store.put(StatePath.submission(ReleaseWatchTests.repo, start.version), data: try StateFileCoder.encode(start))
        let watch = base.watch()
        await watch.refresh()
        let blocker = try #require(await watch.blockers.first { $0.scope == .appStore(ReleaseWatchTests.repo) })
        #expect(blocker.key == "appStore/shariverse/oshikatsu-countdown-ios/firstRelease/1.0.0")
        if case let .appStoreFirstRelease(remaining) = blocker.reason {
            #expect(remaining == 8)
        } else {
            Issue.record("初めての版の残りを知らせていない")
        }
        let notice = try #require(PushNotice.compose([blocker], epics: [], now: ReleaseWatchTests.now).first)
        #expect(notice.target == ["repo": "shariverse/oshikatsu-countdown-ios", "appStore": "setup"])
        #expect(notice.body.contains("8 個"))
    }

    // MARK: - 人の意図

    @Test func rejectsRequestsThatDoNotFitTheRecord() async throws {
        try await base.addRepository()
        let register = envelope("registerBundleId", ["identifier": .string("jp.shilokuma.Other"), "platform": .string("iOS")])
        // 記録が無い
        if case .reject = try await RegisterBundleIdHandler().handle(register, in: context) {} else { Issue.record("記録が無いのに受け付けた") }
        await base.watch().refresh()
        // ビルドの設定に無い Bundle ID
        if case .reject = try await RegisterBundleIdHandler().handle(register, in: context) {} else {
            Issue.record("知らない Bundle ID を受け付けた")
        }
        // アプリが無いうちは、決まった値を書けない
        let apply = envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(.init(price: .free)))
        if case .reject = try await ApplyAppStoreSettingsHandler().handle(apply, in: context) {} else { Issue.record("アプリが無いのに受け付けた") }
        // まだ確かめていない項目は「終わった」にできない
        let confirm = envelope("confirmAppStoreItem", ["item": .string("appPrivacy")])
        if case .reject = try await ConfirmAppStoreItemHandler().handle(confirm, in: context) {} else { Issue.record("確かめていない項目を受け付けた") }
    }

    @Test func rejectsSecondRequestWhileFirstIsPending() async throws {
        try await base.addRepository()
        await base.watch().refresh()
        let first = envelope("registerBundleId", ["identifier": .string("jp.shilokuma.OshiCon"), "platform": .string("iOS")])
        #expect(try await RegisterBundleIdHandler().handle(first, in: context) == .accept)
        // 同じ意図のやり直しは受け付ける
        #expect(try await RegisterBundleIdHandler().handle(first, in: context) == .accept)
        let universal: [String: JSONValue] = ["identifier": .string("jp.shilokuma.OshiCon"), "platform": .string("universal")]
        let second = envelope("registerBundleId", universal, nonce: "01JCN0NCE00000000000000002")
        if case .reject = try await RegisterBundleIdHandler().handle(second, in: context) {} else { Issue.record("送っている途中に受け付けた") }
    }
}
