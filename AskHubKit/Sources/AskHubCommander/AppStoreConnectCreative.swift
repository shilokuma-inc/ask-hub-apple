import AskHubProtocol
import Foundation

// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の App Store Connect の読み書き（`docs/renewal/creative-assets.md`）。
// 読み取りは見回りで、書き込み（ライブラリに上げる・版の言語に置く）は人の意図を受け付けた後だけ使う

/// クリエイティブアセットの App Store Connect の読み書き（テストでは差し替える）
public protocol AppStoreConnectCreative: Sendable {
    /// App 情報の言語ごとのアプリ名（言語 → 名前）。準備しているほうの App 情報（配信中の版があれば、次の版のもの）を読む
    func appNames(of appID: String) async throws(AppStoreConnectError) -> [String: String]
    /// クリエイティブアセットの画像を 1 枚上げる（カテゴリは `CREATIVE_ASSETS`。予約 → 送る → 終わりを伝える）。処理は待たない。上げた画像の id を返す
    func sendCreativeImage(
        to libraryID: String,
        fileName: String,
        referenceName: String,
        data: Data
    ) async throws(AppStoreConnectError) -> String
    /// クリエイティブアセットの配置の種類ごとの、配置グループと受け付ける仕様（参照データの `placementTypes` の `specMappings`）
    func creativePlacementGroups() async throws(AppStoreConnectError) -> [String: [AppStoreCreativeGroup]]
    /// 版の言語の、その種類のクリエイティブアセットの配置
    func creativePlacements(
        on localizationID: String,
        placementType: String
    ) async throws(AppStoreConnectError) -> [AppStoreCreativePlacement]
    /// 画像を、版の言語のその種類・配置グループに置く。配置の id を返す
    func placeCreative(
        _ imageID: String,
        on localizationID: String,
        placementType: String,
        group: String
    ) async throws(AppStoreConnectError) -> String
}

/// クリエイティブアセットの配置グループと、そこに置ける画像の仕様
public struct AppStoreCreativeGroup: Equatable, Sendable {
    public var id: String
    public var specs: [String]

    public init(id: String, specs: [String]) {
        self.id = id
        self.specs = specs
    }
}

/// 版の言語に置いたクリエイティブアセット
public struct AppStoreCreativePlacement: Equatable, Sendable {
    public var id: String
    public var imageID: String
    public var group: String

    public init(id: String, imageID: String, group: String) {
        self.id = id
        self.imageID = imageID
        self.group = group
    }
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

extension AppStoreConnectClient {
    /// 配置の種類・配置グループ・仕様の id の形（列挙でなく文字列）
    static func isAssetName(_ text: String) -> Bool { text.wholeMatch(of: #/[A-Za-z0-9_.-]{1,80}/#) != nil }

    public func creativePlacementGroups() async throws(AppStoreConnectError) -> [String: [AppStoreCreativeGroup]] {
        let types = CreativeKind.allCases.map(\.placementType).joined(separator: ",")
        let query = [
            URLQueryItem(name: "fields[appAssetLibraryRefData]", value: "placementTypes"),
            URLQueryItem(name: "filter[placementTypes]", value: types)
        ]
        let response = try await get("v1/appAssetLibraryRefData", query: query, as: AppStoreConnectCreativeRefDataResponse.self)
        var groups: [String: [AppStoreCreativeGroup]] = [:]
        for type in response.data.flatMap({ $0.attributes?.placementTypes ?? [] }) {
            guard let id = type.placementTypeId, Self.isAssetName(id) else { continue }
            for mapping in type.specMappings ?? [] {
                guard let group = mapping.placementGroupId, Self.isAssetName(group) else { continue }
                groups[id, default: []].append(.init(id: group, specs: (mapping.specs ?? []).filter(Self.isAssetName)))
            }
        }
        return groups
    }

    public func creativePlacements(
        on localizationID: String,
        placementType: String
    ) async throws(AppStoreConnectError) -> [AppStoreCreativePlacement] {
        try Self.checkID(localizationID)
        guard Self.isAssetName(placementType) else { throw .malformed("配置の種類の形が違う") }
        let query = [
            URLQueryItem(name: "filter[placementType]", value: placementType),
            URLQueryItem(name: "include", value: "image"),
            URLQueryItem(name: "fields[appAssetLibraryPlacements]", value: "placementGroup,image"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let response = try await get(
            "v1/appStoreVersionLocalizations/\(localizationID)/placements", query: query, as: AppStoreConnectPlacementsResponse.self
        )
        return response.data.compactMap { item in
            guard Self.isID(item.id), let group = item.attributes?.placementGroup, Self.isAssetName(group),
                  let imageID = item.relationships?.image?.data?.id, Self.isID(imageID) else { return nil }
            return .init(id: item.id, imageID: imageID, group: group)
        }
    }

    public func placeCreative(
        _ imageID: String,
        on localizationID: String,
        placementType: String,
        group: String
    ) async throws(AppStoreConnectError) -> String {
        try Self.checkID(imageID)
        try Self.checkID(localizationID)
        guard Self.isAssetName(placementType), Self.isAssetName(group) else { throw .malformed("配置の種類・配置グループの形が違う") }
        let body = try Self.document(
            "appAssetLibraryPlacements",
            attributes: ["placementType": placementType, "placementGroup": group],
            relationships: [
                "image": ("appAssetLibraryImages", imageID),
                "appStoreVersionLocalization": ("appStoreVersionLocalizations", localizationID)
            ]
        )
        let data = try await send("POST", "v1/appAssetLibraryPlacements", body: body)
        guard let created = try? JSONDecoder().decode(AppStoreConnectCreated.self, from: data), Self.isID(created.data.id) else {
            throw .malformed("作ったクリエイティブアセットの配置の応答")
        }
        return created.data.id
    }

    public func sendCreativeImage(
        to libraryID: String,
        fileName: String,
        referenceName: String,
        data: Data
    ) async throws(AppStoreConnectError) -> String {
        try await sendImage(to: libraryID, fileName: fileName, referenceName: referenceName, data: data, category: "CREATIVE_ASSETS")
    }
}

/// 参照データのクリエイティブアセットの配置の種類（読むところだけ）。`data` が 1 件でも並びでも読む
struct AppStoreConnectCreativeRefDataResponse: Decodable {
    struct Mapping: Decodable {
        var placementGroupId: String?
        var specs: [String]?
    }

    struct PlacementType: Decodable {
        var placementTypeId: String?
        var specMappings: [Mapping]?
    }

    struct Attributes: Decodable {
        var placementTypes: [PlacementType]?
    }

    var data: [AppStoreConnectResource<Attributes>]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let one = try? container.decode(AppStoreConnectResource<Attributes>.self, forKey: .data) {
            data = [one]
        } else {
            data = try container.decode([AppStoreConnectResource<Attributes>].self, forKey: .data)
        }
    }
}

struct AppStoreConnectAppNamesResponse: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var name: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}
