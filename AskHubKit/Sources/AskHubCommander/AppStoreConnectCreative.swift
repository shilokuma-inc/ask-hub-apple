import AskHubProtocol
import Foundation

// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の App Store Connect の読み書き（`docs/renewal/creative-assets.md`）。
// 読み取りは見回りで、書き込み（ライブラリに上げる・版の言語に置く）は人の意図を受け付けた後だけ使う

/// クリエイティブアセットの App Store Connect の読み書き（テストでは差し替える）
public protocol AppStoreConnectCreative: Sendable {
    /// App 情報の言語ごとのアプリ名（言語 → 名前）。準備しているほうの App 情報（配信中の版があれば、次の版のもの）を読む
    func appNames(of appID: String) async throws(AppStoreConnectError) -> [String: String]
}

extension AppStoreConnectClient: AppStoreConnectCreative {
    public func appNames(of appID: String) async throws(AppStoreConnectError) -> [String: String] {
        try Self.checkID(appID)
        let infos = try await get(
            "v1/apps/\(appID)/appInfos",
            query: [URLQueryItem(name: "limit", value: "10")],
            as: AppStoreConnectAppInfosResponse.self
        )
        // 配信中の版があるアプリは App 情報を 2 つ持つ。準備しているほう（配信中でないもの）を見る
        guard let info = infos.data.first(where: { $0.attributes?.state != "READY_FOR_DISTRIBUTION" }) ?? infos.data.first,
              Self.isID(info.id) else { return [:] }
        let localizations = try await get(
            "v1/appInfos/\(info.id)/appInfoLocalizations",
            query: [
                URLQueryItem(name: "fields[appInfoLocalizations]", value: "locale,name"),
                URLQueryItem(name: "limit", value: "50")
            ],
            as: AppStoreConnectAppNamesResponse.self
        )
        var names: [String: String] = [:]
        for item in localizations.data {
            guard let locale = item.attributes?.locale, LocalizedText.isLocale(locale),
                  let name = item.attributes?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[locale] = name
        }
        return names
    }
}

struct AppStoreConnectAppNamesResponse: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var name: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}
