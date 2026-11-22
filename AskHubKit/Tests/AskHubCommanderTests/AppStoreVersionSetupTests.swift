@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 新しいアプリを App Store に載せる準備のうち、初めての版の項目（サポート URL・著作権表示・App Review の連絡先）。
/// 版の枠があるときだけ確かめ、決まった値は人が押したら、まだ書いていない言語・版に書く
struct AppStoreVersionSetupTests {
    let setup = AppStoreSetupTests()
    var base: ReleaseWatchTests { setup.base }
    static let version = MarketingVersion(rawValue: "1.0.0")!

    func slot(_ id: String, _ platform: AppStorePlatform = .iOS) -> SubmissionFile.VersionSlot {
        .init(platform: platform, id: id, at: Timestamp(ReleaseWatchTests.now))
    }

    /// 初めての版のリリースを始めた記録（`end` を渡すと、終わった記録）
    func putRelease(slots: [SubmissionFile.VersionSlot], end: SubmissionFile.End? = nil) async throws {
        let file = SubmissionFile(
            repo: ReleaseWatchTests.repo,
            version: Self.version,
            origin: .askhub,
            start: .init(
                approval: IntentReference(keyId: AppStoreSetupTests.keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000009")!),
                at: Timestamp(ReleaseWatchTests.now)
            ),
            end: end,
            appStoreVersions: slots,
            createdAt: Timestamp(ReleaseWatchTests.now),
            updatedAt: Timestamp(ReleaseWatchTests.now)
        )
        await base.store.put(StatePath.submission(ReleaseWatchTests.repo, Self.version), data: try StateFileCoder.encode(file))
    }

    /// 人がリリースをやめた印
    func abandoned() -> SubmissionFile.End {
        let approval = IntentReference(keyId: AppStoreSetupTests.keyID, nonce: ULID(rawValue: "01JCN0NCE0000000000000000A")!)
        return .init(reason: .abandoned, at: Timestamp(base.clock.now), approval: approval)
    }

    func versionSetup(_ id: String, _ state: AppStoreVersionSetupState) {
        base.appStore.state.withLock { $0.versionSetups[id] = state }
    }

    /// 初めての版の項目の書き込み（ほかの段取りの書き込みは除く）
    func versionWrites() -> [String] {
        base.appStore.state.withLock { $0.writes.filter { $0.hasPrefix("setCopyright") || $0.hasPrefix("setVersionURLs") } }
    }

    func item(_ kind: AppStoreSetupFile.ItemKind) async throws -> AppStoreSetupFile.Item? {
        try await setup.setup()?.item(kind)
    }

    @Test func checksVersionItemsOnlyWhileVersionSlotExists() async throws {
        try await base.addRepository()
        setup.app()
        versionSetup("v-1", .init(
            localizations: [.init(id: "l-ja", locale: "ja"), .init(id: "l-en", locale: "en-US", supportUrl: "https://example.com/en")],
            missingReviewContact: [.phone, .email]
        ))
        let watch = base.watch()
        await watch.refresh()
        // リリースを始めていない（版の枠が無い）ので、版の項目は持たない
        var file = try #require(try await setup.setup())
        #expect(!file.items.contains { $0.id.isVersionItem })

        // リリースを始めて枠を作ったら、30 分を待たずに確かめる
        try await putRelease(slots: [slot("v-1")])
        await watch.refresh()
        file = try #require(try await setup.setup())
        #expect([.supportUrl, .copyright, .reviewContact].allSatisfy { setup.items(file)[$0] == .todo })
        #expect(file.item(.supportUrl)?.note == "まだ書いていない言語: ja")
        // 連絡先は、入れていない欄の名前だけを書く
        #expect(file.item(.reviewContact)?.note == "まだ入れていない欄: 電話番号・メールアドレス")
        let blocker = try #require(await watch.blockers.first { $0.scope == .appStore(ReleaseWatchTests.repo) })
        #expect(blocker.reason == .appStoreFirstRelease(remaining: 11))

        // App Store Connect で入れたら、次に読むときに終わりにする
        versionSetup("v-1", .init(
            copyright: "2026 Shilokuma Inc.",
            localizations: [
                .init(id: "l-ja", locale: "ja", supportUrl: "https://example.com/support"),
                .init(id: "l-en", locale: "en-US", supportUrl: "https://example.com/support")
            ]
        ))
        base.clock.advance(minutes: 31)
        await watch.refresh()
        file = try #require(try await setup.setup())
        #expect([.supportUrl, .copyright, .reviewContact].allSatisfy { setup.items(file)[$0] == .done })
        #expect(file.item(.supportUrl)?.note == "https://example.com/support")
        #expect(file.item(.copyright)?.note == "2026 Shilokuma Inc.")
        #expect(file.item(.reviewContact)?.note == nil)

        // リリースをやめたら、版の項目を外す
        try await putRelease(slots: [slot("v-1")], end: abandoned())
        await watch.refresh()
        #expect(try await item(.supportUrl) == nil)
    }

    @Test func writesVersionSettingsOnlyToUnsetLanguagesAndVersions() async throws {
        try await base.addRepository()
        setup.app()
        versionSetup("v-1", .init(
            localizations: [.init(id: "l-ja", locale: "ja"), .init(id: "l-en", locale: "en-US", supportUrl: "https://example.com/en")]
        ))
        versionSetup("v-2", .init(copyright: "2025 Shilokuma Inc.", localizations: [.init(id: "m-ja", locale: "ja")]))
        try await putRelease(slots: [slot("v-1"), slot("v-2", .macOS)])
        let watch = base.watch()
        await watch.refresh()
        // 枠が 2 つなら、どの枠のことかを書く
        #expect(try await item(.supportUrl)?.note == "まだ書いていない言語: iOS の ja・macOS の ja")
        #expect(try await item(.copyright)?.note == "まだ書いていない版: iOS")

        let settings = AppStoreSettings(supportUrl: "https://example.com/support", marketingUrl: "https://example.com", copyright: "2026 Shilokuma Inc.")
        let apply = setup.envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(settings))
        #expect(try await ApplyAppStoreSettingsHandler().handle(apply, in: setup.context) == .accept)
        await watch.refresh()
        // 書いてある英語のサポート URL と macOS の著作権表示は上書きしない。マーケティング URL は書いていない言語に書く
        #expect(versionWrites() == [
            "setCopyright v-1 2026 Shilokuma Inc.",
            "setVersionURLs l-ja https://example.com/support https://example.com",
            "setVersionURLs l-en - https://example.com",
            "setVersionURLs m-ja https://example.com/support https://example.com"
        ])
        let file = try #require(try await setup.setup())
        #expect(file.settingsRequest?.doneAt != nil && file.settingsRequest?.failures == nil)
        #expect(setup.items(file)[.supportUrl] == .done && setup.items(file)[.copyright] == .done)
        // 枠ごとに違う値なら、今の値を補足に出さない
        #expect(file.item(.copyright)?.note == nil)
    }

    @Test func refusesVersionSettingsBeforeVersionSlotIsChecked() async throws {
        try await base.addRepository()
        setup.app()
        await base.watch().refresh()
        let apply = setup.envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(.init(copyright: "2026 Shilokuma Inc.")))
        if case .reject = try await ApplyAppStoreSettingsHandler().handle(apply, in: setup.context) {} else {
            Issue.record("版の枠が無いのに著作権表示を受け付けた")
        }
    }

    @Test func recordsRefusalWhenSlotIsGoneOrWriteIsRefused() async throws {
        try await base.addRepository()
        setup.app()
        versionSetup("v-1", .init(localizations: [.init(id: "l-ja", locale: "ja")]))
        try await putRelease(slots: [slot("v-1")])
        let watch = base.watch()
        await watch.refresh()
        let apply = setup.envelope(
            "applyAppStoreSettings",
            ApplyAppStoreSettingsIntent.payload(.init(supportUrl: "https://example.com/support", copyright: "2026 Shilokuma Inc."))
        )
        #expect(try await ApplyAppStoreSettingsHandler().handle(apply, in: setup.context) == .accept)
        // 送る前にリリースをやめた（枠が無い）
        try await putRelease(slots: [slot("v-1")], end: abandoned())
        await watch.refresh()
        var file = try #require(try await setup.setup())
        #expect(file.settingsRequest?.failures?.map(\.item) == [.supportUrl, .copyright])
        #expect(file.settingsRequest?.failures?.first?.message.contains("版の枠が無い") == true)
        #expect(versionWrites().isEmpty)

        // 断られたら、理由を書いて知らせる
        try await putRelease(slots: [slot("v-1")])
        base.clock.advance(minutes: 31)
        await watch.refresh()
        let again = setup.envelope(
            "applyAppStoreSettings",
            ApplyAppStoreSettingsIntent.payload(.init(supportUrl: "https://example.com/support")),
            nonce: "01JCN0NCE00000000000000002"
        )
        #expect(try await ApplyAppStoreSettingsHandler().handle(again, in: setup.context) == .accept)
        base.appStore.state.withLock { $0.refusal = .refused(status: 409, detail: "URL に届かない") }
        await watch.refresh()
        file = try #require(try await setup.setup())
        #expect(file.settingsRequest?.failures?.map(\.item) == [.supportUrl])
        #expect(await watch.blockers.contains { $0.reason == .appStoreRefused([.supportUrl]) })
    }

    // MARK: - App Review の連絡先を写す

    static let contact = ReviewContact(values: [
        .firstName: "Taro", .lastName: "Yamada", .phone: "+81 90 0000 0000", .email: "taro@example.com"
    ])

    func version(_ id: String, _ state: AppStoreVersionState) -> AppStoreVersionInfo {
        AppStoreVersionInfo(id: id, platform: .iOS, versionString: "1.0.0", state: state)
    }

    @Test func copiesReviewContactFromOtherAppWithoutRecordingValues() async throws {
        try await base.addRepository()
        setup.app()
        base.appStore.state.withLock { state in
            state.apps += [
                AppStoreApp(id: "6740000010", bundleId: "jp.shilokuma.Half", name: "連絡先が欠けたアプリ"),
                AppStoreApp(id: "6740000009", bundleId: "jp.shilokuma.Other", name: "ほかのアプリ")
            ]
            // 配信中でも、欄が欠けた連絡先は写さない
            state.versionsByApp["6740000010"] = [version("half-live", .readyForDistribution)]
            state.reviewContacts["half-live"] = .init(detailID: "rd-half", contact: .init(values: [.firstName: "Hanako"]))
            // 審査に出していない版の連絡先は使わず、審査に出した（リジェクトされた）版から写す
            state.versionsByApp["6740000009"] = [version("other-draft", .prepareForSubmission), version("other-rejected", .rejected)]
            state.reviewContacts["other-draft"] = .init(detailID: "rd-draft", contact: Self.contact)
            state.reviewContacts["other-rejected"] = .init(detailID: "rd-other", contact: Self.contact)
        }
        versionSetup("v-1", .init(
            localizations: [.init(id: "l-ja", locale: "ja")], missingReviewContact: [.phone, .email], reviewDetailID: "rd-1"
        ))
        try await putRelease(slots: [slot("v-1")])
        let watch = base.watch()
        await watch.refresh()
        let apply = setup.envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(.init(reviewContact: .copyFromOtherApp)))
        #expect(try await ApplyAppStoreSettingsHandler().handle(apply, in: setup.context) == .accept)
        await watch.refresh()
        // まだ入れていない欄だけを、今の App Review の情報に書く
        #expect(base.appStore.state.withLock { $0.writes }.filter { $0.hasPrefix("writeReviewContact") } == [
            "writeReviewContact v-1 contactPhone,contactEmail rd-1"
        ])
        let file = try #require(try await setup.setup())
        #expect(file.settingsRequest?.reviewContactFrom == .init(id: "6740000009", name: "ほかのアプリ"))
        #expect(file.settingsRequest?.failures == nil)
        #expect(file.item(.reviewContact)?.state == .done)
        // 連絡先の値は記録に書かない
        let text = try #require(String(bytes: try StateFileCoder.encode(file), encoding: .utf8))
        #expect(!text.contains("taro@example.com") && !text.contains("+81 90") && !text.contains("Yamada"))
    }

    @Test func leavesReviewContactToHumanWhenNoOtherAppHasOne() async throws {
        try await base.addRepository()
        setup.app()
        versionSetup("v-1", .init(localizations: [.init(id: "l-ja", locale: "ja")], missingReviewContact: ReviewContactField.allCases))
        try await putRelease(slots: [slot("v-1")])
        let watch = base.watch()
        await watch.refresh()
        let apply = setup.envelope("applyAppStoreSettings", ApplyAppStoreSettingsIntent.payload(.init(reviewContact: .copyFromOtherApp)))
        #expect(try await ApplyAppStoreSettingsHandler().handle(apply, in: setup.context) == .accept)
        await watch.refresh()
        let file = try #require(try await setup.setup())
        #expect(file.settingsRequest?.failures?.map(\.item) == [.reviewContact])
        #expect(file.settingsRequest?.failures?.first?.message.contains("App Store Connect で入れて") == true)
        #expect(file.settingsRequest?.reviewContactFrom == nil)
        #expect(await watch.blockers.contains { $0.reason == .appStoreRefused([.reviewContact]) })
    }
}
