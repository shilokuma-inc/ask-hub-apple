import AskHubProtocol
import Foundation

// 新しいアプリを App Store に載せる準備の API（Bundle ID・コンテンツの権利・カテゴリ・プライバシーポリシーの URL・価格・配信の地域・年齢制限。
// 初めての版の項目は `AppStoreConnectVersionSetup.swift`）。
// 読み取りは見回りで、書き込みは人の意図を受け付けたときだけ使う（`docs/renewal/release.md` の「新しいアプリを載せる」）

/// App Store Connect で読んだ、アプリの準備の様子。nil の欄は読めなかった（API が断った・無かった）
public struct AppStoreSetupState: Equatable, Sendable {
    /// App 情報の 1 つの言語（プライバシーポリシーの URL だけを読む）
    public struct InfoLocalization: Equatable, Sendable {
        public var id: String
        public var locale: String
        public var privacyPolicyUrl: String?

        public init(id: String, locale: String, privacyPolicyUrl: String?) {
            self.id = id
            self.locale = locale
            self.privacyPolicyUrl = privacyPolicyUrl
        }
    }

    public var primaryLocale: String?
    /// `contentRightsDeclaration` の App Store Connect の値（`DOES_NOT_USE_THIRD_PARTY_CONTENT` など）。答えていなければ nil
    public var contentRights: String?
    /// 編集できる App 情報（`appInfos`）の id。読めなければ nil
    public var appInfoID: String?
    /// 主なカテゴリの id。選んでいなければ nil
    public var primaryCategory: String?
    /// App 情報の言語
    public var infoLocalizations: [InfoLocalization]
    /// 年齢制限の、答えていない質問（属性の名前）。読めなければ nil
    public var unansweredAgeRatings: [String]?
    /// 価格を決めてある。読めなければ nil
    public var hasPrice: Bool?
    /// 配信の地域を決めてある。読めなければ nil
    public var hasAvailability: Bool?

    public init(
        primaryLocale: String? = nil,
        contentRights: String? = nil,
        appInfoID: String? = nil,
        primaryCategory: String? = nil,
        infoLocalizations: [InfoLocalization] = [],
        unansweredAgeRatings: [String]? = nil,
        hasPrice: Bool? = nil,
        hasAvailability: Bool? = nil
    ) {
        self.primaryLocale = primaryLocale
        self.contentRights = contentRights
        self.appInfoID = appInfoID
        self.primaryCategory = primaryCategory
        self.infoLocalizations = infoLocalizations
        self.unansweredAgeRatings = unansweredAgeRatings
        self.hasPrice = hasPrice
        self.hasAvailability = hasAvailability
    }
}

/// 新しいアプリを載せる準備の API（テストでは差し替える）
public protocol AppStoreConnectListing: Sendable {
    /// Bundle ID のうち、Certificates, Identifiers & Profiles に登録してあるもの
    func registeredBundleIDs(_ identifiers: [String]) async throws(AppStoreConnectError) -> [String]
    func registerBundleID(_ identifier: String, name: String, platform: BundleIDPlatform) async throws(AppStoreConnectError)
    /// アプリの準備の様子（コンテンツの権利・カテゴリ・プライバシーポリシーの URL・年齢制限・価格・配信の地域）
    func setupState(of appID: String) async throws(AppStoreConnectError) -> AppStoreSetupState
    func setContentRights(_ value: ContentRightsDeclaration, of appID: String) async throws(AppStoreConnectError)
    func setCategory(_ primary: String, subcategory: String?, appInfoID: String) async throws(AppStoreConnectError)
    func setPrivacyPolicyURL(_ url: String, localizationID: String) async throws(AppStoreConnectError)
    /// 無料にする（基準の地域の、価格が 0 の価格の点）
    func setFreePrice(of appID: String) async throws(AppStoreConnectError)
    /// すべての地域と、これから足される地域に配信する
    func setAvailableEverywhere(of appID: String) async throws(AppStoreConnectError)
    /// 初めての版の枠の準備の様子（著作権表示・言語ごとのサポート URL とマーケティング URL・App Review の連絡先がそろっているか）
    func versionSetupState(of versionID: String) async throws(AppStoreConnectError) -> AppStoreVersionSetupState
    func setCopyright(_ text: String, versionID: String) async throws(AppStoreConnectError)
    /// 版の 1 つの言語に、サポート URL とマーケティング URL を書く（nil の欄は送らない）
    func setVersionURLs(support: String?, marketing: String?, localizationID: String) async throws(AppStoreConnectError)
    /// この鍵で見られるすべてのアプリ（App Review の連絡先を写すもとを探す）
    func allApps() async throws(AppStoreConnectError) -> [AppStoreApp]
    /// 版の App Review の連絡先（写すもとを読む。値はメモリーの中だけで使う）
    func reviewContact(of versionID: String) async throws(AppStoreConnectError) -> AppStoreReviewContact?
    /// 版の App Review の連絡先のうち、`fields` の欄だけを書く（App Review の情報が無ければ作る）
    func writeReviewContact(
        _ contact: ReviewContact,
        fields: [ReviewContactField],
        detailID: String?,
        versionID: String
    ) async throws(AppStoreConnectError)
}

/// 審査の API と準備の API の両方（司令塔の見回りが使う）
public typealias AppStoreConnecting = AppStoreConnectSubmitting & AppStoreConnectListing

extension AppStoreConnectClient: AppStoreConnectListing {
    /// 無料の価格を決めるときの基準の地域
    static let baseTerritory = "USA"

    /// 年齢制限の質問のうち、答えていなければ審査に出せないもの（`ageRatingDeclarations` の属性）。
    /// 2025 年の新しい質問（広告・健康・メッセージ・保護者の管理・年齢の確認・ユーザーの作るコンテンツ）を含む。
    /// ブラジルだけに効くもの・条件つきのもの・上書きは含めない
    static let requiredAgeRatings = [
        "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "medicalOrTreatmentInformation",
        "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity", "horrorOrFearThemes", "matureOrSuggestiveThemes",
        "violenceCartoonOrFantasy", "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic", "gambling", "unrestrictedWebAccess",
        "advertising", "healthOrWellnessTopics", "messagingAndChat", "parentalControls", "ageAssurance", "userGeneratedContent"
    ]

    public func registeredBundleIDs(_ identifiers: [String]) async throws(AppStoreConnectError) -> [String] {
        let wanted = identifiers.filter(Self.isBundleID)
        guard !wanted.isEmpty else { return [] }
        let query = [
            URLQueryItem(name: "filter[identifier]", value: wanted.joined(separator: ",")),
            URLQueryItem(name: "fields[bundleIds]", value: "identifier"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        let response = try await get("v1/bundleIds", query: query, as: AppStoreConnectIdentifiersResponse.self)
        // 絞り込みが完全一致とは文書に書かれていないので、返った identifier を比べ直す
        return wanted.filter { identifier in response.data.contains { $0.attributes?.identifier == identifier } }
    }

    public func registerBundleID(_ identifier: String, name: String, platform: BundleIDPlatform) async throws(AppStoreConnectError) {
        guard Self.isBundleID(identifier) else { throw .malformed("Bundle ID の形が違う") }
        let body = try Self.document(
            "bundleIds",
            attributes: ["identifier": identifier, "name": name, "platform": platform.appStoreConnectValue]
        )
        _ = try await send("POST", "v1/bundleIds", body: body)
    }

    public func setupState(of appID: String) async throws(AppStoreConnectError) -> AppStoreSetupState {
        try Self.checkID(appID)
        var state = AppStoreSetupState()
        let app = try await get(
            "v1/apps/\(appID)",
            query: [URLQueryItem(name: "fields[apps]", value: "primaryLocale,contentRightsDeclaration")],
            as: AppStoreConnectSingle<AppStoreConnectAppAttributes>.self
        )
        state.primaryLocale = app.data.attributes?.primaryLocale
        state.contentRights = app.data.attributes?.contentRightsDeclaration
        try await readAppInfo(of: appID, into: &state)
        // 決めていない価格・配信の地域は 404 で返る見込み（文書に書かれていない）
        let schedule = try await getIfPresent(
            "v1/apps/\(appID)/appPriceSchedule",
            query: [URLQueryItem(name: "include", value: "manualPrices"), URLQueryItem(name: "limit[manualPrices]", value: "1")],
            as: AppStoreConnectPriceScheduleResponse.self
        )
        state.hasPrice = !(schedule?.data.relationships?.manualPrices?.data ?? []).isEmpty
        state.hasAvailability = try await getIfPresent(
            "v1/apps/\(appID)/appAvailabilityV2",
            query: [],
            as: AppStoreConnectSingle<AppStoreConnectEmptyAttributes>.self
        ) != nil
        return state
    }

    /// 準備しているほうの App 情報（カテゴリ・年齢制限・言語ごとのプライバシーポリシーの URL）を読む
    private func readAppInfo(of appID: String, into state: inout AppStoreSetupState) async throws(AppStoreConnectError) {
        // 関係の相手の id（`data`）は、include で求めたときだけ返る。カテゴリも求める（求めないと、決めてあっても無いと読む）
        let infos = try await get(
            "v1/apps/\(appID)/appInfos",
            query: [
                URLQueryItem(name: "include", value: "ageRatingDeclaration,primaryCategory"),
                URLQueryItem(name: "limit", value: "10")
            ],
            as: AppStoreConnectAppInfosResponse.self
        )
        // 配信中の版があるアプリは App 情報を 2 つ持つ。準備しているほう（配信中でないもの）を見る
        guard let info = infos.data.first(where: { $0.attributes?.state != "READY_FOR_DISTRIBUTION" }) ?? infos.data.first,
              Self.isID(info.id) else { return }
        state.appInfoID = info.id
        state.primaryCategory = info.relationships?.primaryCategory?.data?.id
        let ratingID = info.relationships?.ageRatingDeclaration?.data?.id
        if let rating = infos.included?.first(where: { $0.type == "ageRatingDeclarations" && $0.id == ratingID }) {
            state.unansweredAgeRatings = Self.requiredAgeRatings.filter { (rating.attributes?[$0] ?? .null) == .null }
        }
        let localizations = try await get(
            "v1/appInfos/\(info.id)/appInfoLocalizations",
            query: [
                URLQueryItem(name: "fields[appInfoLocalizations]", value: "locale,privacyPolicyUrl"),
                URLQueryItem(name: "limit", value: "50")
            ],
            as: AppStoreConnectInfoLocalizationsResponse.self
        )
        state.infoLocalizations = localizations.data.compactMap { item in
            guard Self.isID(item.id), let locale = item.attributes?.locale else { return nil }
            return .init(id: item.id, locale: locale, privacyPolicyUrl: item.attributes?.privacyPolicyUrl)
        }
    }

    public func setContentRights(_ value: ContentRightsDeclaration, of appID: String) async throws(AppStoreConnectError) {
        try Self.checkID(appID)
        let body = try Self.document("apps", id: appID, attributes: ["contentRightsDeclaration": value.appStoreConnectValue])
        _ = try await send("PATCH", "v1/apps/\(appID)", body: body)
    }

    public func setCategory(_ primary: String, subcategory: String?, appInfoID: String) async throws(AppStoreConnectError) {
        try Self.checkID(appInfoID)
        guard AppStoreSettings.isCategory(primary), subcategory.map(AppStoreSettings.isCategory) ?? true else {
            throw .malformed("カテゴリの形が違う")
        }
        var relationships: [String: (type: String, id: String)] = ["primaryCategory": ("appCategories", primary)]
        if let subcategory { relationships["primarySubcategoryOne"] = ("appCategories", subcategory) }
        let body = try Self.document("appInfos", id: appInfoID, relationships: relationships)
        _ = try await send("PATCH", "v1/appInfos/\(appInfoID)", body: body)
    }

    public func setPrivacyPolicyURL(_ url: String, localizationID: String) async throws(AppStoreConnectError) {
        try Self.checkID(localizationID)
        guard AppStoreSettings.isURL(url) else { throw .malformed("プライバシーポリシーの URL の形が違う") }
        let body = try Self.document("appInfoLocalizations", id: localizationID, attributes: ["privacyPolicyUrl": url])
        _ = try await send("PATCH", "v1/appInfoLocalizations/\(localizationID)", body: body)
    }

    public func setFreePrice(of appID: String) async throws(AppStoreConnectError) {
        try Self.checkID(appID)
        guard let point = try await freePricePoint(of: appID) else {
            throw .refused(status: 404, detail: "\(Self.baseTerritory) の価格が 0 の価格の点が見つからない")
        }
        let local = "${free}"
        let price: [String: Any] = [
            "type": "appPrices",
            "id": local,
            "attributes": ["startDate": NSNull()],
            "relationships": ["appPricePoint": ["data": ["type": "appPricePoints", "id": point]]]
        ]
        let relationships: [String: Any] = [
            "app": ["data": ["type": "apps", "id": appID]],
            "baseTerritory": ["data": ["type": "territories", "id": Self.baseTerritory]],
            "manualPrices": ["data": [["type": "appPrices", "id": local]]]
        ]
        let body = try Self.json(["data": ["type": "appPriceSchedules", "relationships": relationships], "included": [price]])
        _ = try await send("POST", "v1/appPriceSchedules", body: body)
    }

    /// 基準の地域の、価格（`customerPrice`）が 0 の価格の点の id。ページを最後まで追う
    private func freePricePoint(of appID: String) async throws(AppStoreConnectError) -> String? {
        var query = [
            URLQueryItem(name: "filter[territory]", value: Self.baseTerritory),
            URLQueryItem(name: "fields[appPricePoints]", value: "customerPrice"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        for _ in 0..<20 {
            let page = try await get("v1/apps/\(appID)/appPricePoints", query: query, as: AppStoreConnectPricePointsResponse.self)
            let free = page.data.first { $0.attributes?.customerPrice.flatMap { Decimal(string: $0) } == 0 }
            if let free, Self.isPricePointID(free.id) { return free.id }
            guard let next = page.links?.next.flatMap(URLComponents.init(string:))?.queryItems, !next.isEmpty else { return nil }
            query = next
        }
        return nil
    }

    public func setAvailableEverywhere(of appID: String) async throws(AppStoreConnectError) {
        try Self.checkID(appID)
        let territories = try await get(
            "v1/territories",
            query: [
                URLQueryItem(name: "fields[territories]", value: "currency"),
                URLQueryItem(name: "limit", value: String(Self.pageLimit))
            ],
            as: AppStoreConnectTerritoriesResponse.self
        ).data.map(\.id).filter(Self.isTerritory)
        guard !territories.isEmpty else { throw .malformed("地域の一覧が空") }
        let included: [[String: Any]] = territories.map { territory in
            [
                "type": "territoryAvailabilities",
                "id": "${\(territory)}",
                "attributes": ["available": true],
                "relationships": ["territory": ["data": ["type": "territories", "id": territory]]]
            ]
        }
        let relationships: [String: Any] = [
            "app": ["data": ["type": "apps", "id": appID]],
            "territoryAvailabilities": ["data": territories.map { ["type": "territoryAvailabilities", "id": "${\($0)}"] }]
        ]
        let data: [String: Any] = [
            "type": "appAvailabilities",
            "attributes": ["availableInNewTerritories": true],
            "relationships": relationships
        ]
        let body = try Self.json(["data": data, "included": included])
        _ = try await send("POST", "v2/appAvailabilities", body: body)
    }

    // MARK: - 形

    /// 地域の id（英大文字 3 字。`USA`・`JPN` など）。ローカルの id に入れるので、ほかの文字を含むものは使わない
    static func isTerritory(_ text: String) -> Bool {
        text.utf8.count == 3 && text.utf8.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }
    }

    /// 価格の点の id（base64 の英数字と `=`・`-`・`_`）
    static func isPricePointID(_ text: String) -> Bool {
        (1...200).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || [UInt8(ascii: "="), UInt8(ascii: "-"), UInt8(ascii: "_")].contains(byte)
        }
    }

    static func json(_ object: [String: Any]) throws(AppStoreConnectError) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw .malformed("本文を作れない")
        }
    }
}

struct AppStoreConnectSingle<Attributes: Decodable>: Decodable {
    var data: AppStoreConnectResource<Attributes>
}

struct AppStoreConnectEmptyAttributes: Decodable {}

struct AppStoreConnectAppAttributes: Decodable {
    var primaryLocale: String?
    var contentRightsDeclaration: String?
}

struct AppStoreConnectIdentifiersResponse: Decodable {
    struct Attributes: Decodable {
        var identifier: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}

struct AppStoreConnectAppInfosResponse: Decodable {
    struct Attributes: Decodable {
        var state: String?
    }

    struct Relationships: Decodable {
        var primaryCategory: AppStoreConnectRelationship?
        var ageRatingDeclaration: AppStoreConnectRelationship?
    }

    struct Item: Decodable {
        var id: String
        var attributes: Attributes?
        var relationships: Relationships?
    }

    var data: [Item]
    /// 年齢制限の申告（属性の値は文字列・真偽値・null が混ざるので、JSON の値のまま読む）
    var included: [AppStoreConnectResource<[String: JSONValue]>]?
}

struct AppStoreConnectInfoLocalizationsResponse: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var privacyPolicyUrl: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}

struct AppStoreConnectPriceScheduleResponse: Decodable {
    struct ToMany: Decodable {
        var data: [AppStoreConnectLink]?
    }

    struct Relationships: Decodable {
        var manualPrices: ToMany?
    }

    struct Item: Decodable {
        var id: String
        var relationships: Relationships?
    }

    var data: Item
}

struct AppStoreConnectPricePointsResponse: Decodable {
    struct Attributes: Decodable {
        var customerPrice: String?
    }

    struct Links: Decodable {
        var next: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
    var links: Links?
}

struct AppStoreConnectTerritoriesResponse: Decodable {
    var data: [AppStoreConnectResource<AppStoreConnectEmptyAttributes>]
}
