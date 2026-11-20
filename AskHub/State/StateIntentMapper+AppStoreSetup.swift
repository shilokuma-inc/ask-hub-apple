import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - 新しいアプリを App Store に載せる準備

extension StateIntentMapper {
    /// 準備の操作を送れるか。Bundle ID の登録はビルドの設定にある Bundle ID だけ、決まった値はアプリがあるときだけ、
    /// どちらも前の書き込みを送り終えてから。「終わった」は確かめた項目のうち終わっていないもの（アプリの作成を除く）。
    /// 出さない・出すに戻すは、対象のリポジトリならいつでも
    func supportsAppStoreSetupIntent(_ intent: HumanIntent) -> Bool {
        switch intent {
        case let .excludeFromAppStore(repositoryID, excluded):
            guard index.repositories[repositoryID] != nil else { return false }
            return (index.appStoreSetups[repositoryID]?.isExcluded ?? false) != excluded

        case let .registerBundleId(repositoryID, identifier, _):
            guard let entry = index.appStoreSetups[repositoryID], entry.isActive, !entry.isWriting else { return false }
            return entry.bundleIDs.contains(identifier)

        case let .applyAppStoreSettings(repositoryID, request):
            guard let entry = index.appStoreSetups[repositoryID], entry.isActive, !entry.isWriting else { return false }
            return entry.hasApp && !request.isEmpty

        case let .confirmAppStoreItem(repositoryID, item):
            guard let entry = index.appStoreSetups[repositoryID], entry.isActive else { return false }
            return item != .app && entry.confirmable.contains(item)

        default:
            return false
        }
    }

    /// リリースの操作と App Store の準備の操作の送る形
    func releaseFlowDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case .registerBundleId, .applyAppStoreSettings, .confirmAppStoreItem, .excludeFromAppStore:
            try appStoreSetupDraft(intent)
        default:
            try submissionDraft(intent)
        }
    }

    func appStoreSetupDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        guard supportsAppStoreSetupIntent(intent) else {
            throw ClientServiceError(message: "この App Store の準備の操作は、いまは送れません。取り直してから送ってください")
        }
        switch intent {
        case let .excludeFromAppStore(repositoryID, excluded):
            return .excludeFromAppStore(try repository(repositoryID), excluded: excluded)

        case let .registerBundleId(repositoryID, identifier, platform):
            return .registerBundleId(try repository(repositoryID), identifier: identifier, platform: Self.platform(platform))

        case let .applyAppStoreSettings(repositoryID, request):
            let settings = try Self.settings(request)
            return .applyAppStoreSettings(try repository(repositoryID), settings: settings)

        case let .confirmAppStoreItem(repositoryID, item):
            guard let kind = AppStoreSetupFile.ItemKind(rawValue: item.rawValue) else { throw Self.unsupported }
            return .confirmAppStoreItem(try repository(repositoryID), item: kind)

        default:
            throw Self.unsupported
        }
    }

    private static func platform(_ platform: AppStoreSetup.BundlePlatform) -> BundleIDPlatform {
        switch platform {
        case .iOS: .iOS
        case .macOS: .macOS
        case .universal: .universal
        }
    }

    /// 画面で選んだ値を、送る形にする。プライバシーポリシーの URL は前後の空白を外して確かめる
    static func settings(_ request: AppStoreSettingsRequest) throws(ClientServiceError) -> AppStoreSettings {
        var settings = AppStoreSettings()
        switch request.contentRights {
        case .doesNotUseThirdPartyContent?: settings.contentRights = .doesNotUseThirdPartyContent
        case .usesThirdPartyContent?: settings.contentRights = .usesThirdPartyContent
        case nil: break
        }
        settings.primaryCategory = request.category?.primary
        settings.primarySubcategory = request.category?.subcategory
        if let url = request.privacyPolicyURL?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard AppStoreSettings.isURL(url) else {
                throw ClientServiceError(message: "プライバシーポリシーの URL は https:// で始まる URL にしてください")
            }
            settings.privacyPolicyUrl = url
        }
        settings.price = request.free ? .free : nil
        settings.availability = request.everywhere ? .allTerritories : nil
        guard settings.problems.isEmpty else { throw ClientServiceError(message: "書く値を 1 つ以上選んでください") }
        return settings
    }
}
