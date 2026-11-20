@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let appStoreSetupKinds: [Kind] = [
        Kind(vectors: "payloads/registerBundleId.json", kind: "registerBundleId", target: nil, targetVersion: nil) {
            try RegisterBundleIdIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/applyAppStoreSettings.json", kind: "applyAppStoreSettings", target: nil, targetVersion: nil) {
            try ApplyAppStoreSettingsIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/confirmAppStoreItem.json", kind: "confirmAppStoreItem", target: nil, targetVersion: nil) {
            try ConfirmAppStoreItemIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/excludeFromAppStore.json", kind: "excludeFromAppStore", target: nil, targetVersion: nil) {
            try ExcludeFromAppStoreIntent(envelope: $0).payload
        }
    ]
}

/// 新しいアプリを App Store に載せる準備の記録（`app-store.json`）と、その人の意図
struct AppStoreSetupProtocolTests {
    private static let at = Timestamp(rawValue: "2026-11-20T01:00:00Z")!
    private static let reference = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
    )

    private func file(items: [AppStoreSetupFile.Item], excluded: Bool = false, released: Bool = false) -> AppStoreSetupFile {
        AppStoreSetupFile(
            repo: RepositoryFullName(rawValue: "shilokuma-inc/new-app-ios")!,
            bundleIds: ["jp.shilokuma.NewApp"],
            items: items,
            excluded: excluded ? .init(approval: Self.reference, at: Self.at) : nil,
            releasedAt: released ? Self.at : nil,
            createdAt: Self.at,
            updatedAt: Self.at
        )
    }

    private func item(
        _ kind: AppStoreSetupFile.ItemKind,
        _ state: AppStoreSetupFile.ItemState,
        confirmed: Bool = false
    ) -> AppStoreSetupFile.Item {
        .init(id: kind, state: state, checkedAt: Self.at, confirmed: confirmed ? .init(approval: Self.reference, at: Self.at) : nil)
    }

    private func envelope(kind: String, payload: [String: JSONValue], target: IntentEnvelope.Target? = nil) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: RepositoryFullName(rawValue: "shilokuma-inc/new-app-ios"),
            target: target,
            targetVersion: nil,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-20T02:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func showsOnlyAppItemsUntilFirstRelease() {
        let setup = file(items: [item(.bundleId, .unknown), item(.app, .todo), item(.ageRating, .todo), item(.appPrivacy, .unknown)])
        #expect(setup.pendingItems(firstRelease: false).map(\.id) == [.bundleId, .app])
        #expect(setup.pendingItems(firstRelease: true).map(\.id) == [.bundleId, .app, .ageRating, .appPrivacy])
    }

    @Test func treatsConfirmedItemsAsDone() {
        let setup = file(items: [item(.app, .done), item(.appPrivacy, .unknown, confirmed: true), item(.ageRating, .todo, confirmed: true)])
        #expect(setup.pendingItems(firstRelease: true).isEmpty)
    }

    @Test func showsNothingWhenExcludedOrReleased() {
        let items = [item(.app, .todo)]
        #expect(file(items: items, excluded: true).pendingItems(firstRelease: true).isEmpty)
        #expect(file(items: items, released: true).pendingItems(firstRelease: true).isEmpty)
    }

    @Test func picksMainBundleID() {
        let sandbox = ["jp.shilokuma.AskHubSandbox", "jp.shilokuma.AskHubSandboxTests"]
        #expect(AppStoreSetupFile.mainBundleID(among: sandbox) == "jp.shilokuma.AskHubSandbox")
        // 拡張は本体の後ろに付くので、本体を先に選ぶ
        #expect(AppStoreSetupFile.mainBundleID(among: ["jp.shilokuma.NewApp.Widget", "jp.shilokuma.NewApp", "jp.shilokuma.NewAppUITests"])
            == "jp.shilokuma.NewApp")
        #expect(AppStoreSetupFile.mainBundleID(among: ["jp.shilokuma.NewAppTests"]) == nil)
    }

    @Test func settingsListOnlyWrittenItems() {
        let settings = AppStoreSettings(primaryCategory: "GAMES", primarySubcategory: "GAMES_PUZZLE", price: .free)
        #expect(settings.items == [.category, .price])
        #expect(settings.problems.isEmpty)
        #expect(!AppStoreSettings().problems.isEmpty)
    }

    @Test func refusesTargetsAndOtherKinds() {
        let target = IntentEnvelope.Target(type: "repository", id: "x")
        #expect(throws: MalformedIntent.self) {
            let payload: [String: JSONValue] = ["excluded": .bool(true)]
            return try ExcludeFromAppStoreIntent(envelope: envelope(kind: "excludeFromAppStore", payload: payload, target: target))
        }
        #expect(throws: MalformedIntent.self) {
            try ConfirmAppStoreItemIntent(envelope: envelope(kind: "excludeFromAppStore", payload: ["item": .string("appPrivacy")]))
        }
    }

    @Test func payloadsRoundTrip() throws {
        let settings = AppStoreSettings(contentRights: .doesNotUseThirdPartyContent, privacyPolicyUrl: "https://example.com/privacy")
        let read = try ApplyAppStoreSettingsIntent(
            envelope: envelope(kind: "applyAppStoreSettings", payload: ApplyAppStoreSettingsIntent.payload(settings))
        )
        #expect(read.settings == settings)
        let payload = RegisterBundleIdIntent.payload(identifier: "jp.shilokuma.NewApp", platform: .universal)
        let register = try RegisterBundleIdIntent(envelope: envelope(kind: "registerBundleId", payload: payload))
        #expect(register.identifier == "jp.shilokuma.NewApp" && register.platform == .universal)
    }
}
