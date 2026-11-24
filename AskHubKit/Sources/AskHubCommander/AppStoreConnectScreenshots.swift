import AskHubProtocol
import CryptoKit
import Foundation

// App Store Connect のスクショ（App Asset Library。API 4.5.1 で appScreenshotSets / appScreenshots に替わった）。
// 画像はアプリに 1 つのライブラリに上げ、配置（placement）で版の言語の表示サイズ（配置グループ）に置く
// （`docs/renewal/release.md` の「スクショ」）。書き込みは人が審査に出したときだけ

/// 版の 1 つの言語の、1 つの表示サイズのスクショ
public struct AppStoreScreenshotSet: Equatable, Sendable {
    /// 表示サイズ（App Asset Library の配置グループ。`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など。知らない値もそのまま持つ）
    public var displayType: String
    /// 並びの順のスクショ
    public var screenshots: [AppStoreScreenshot]

    public init(displayType: String, screenshots: [AppStoreScreenshot]) {
        self.displayType = displayType
        self.screenshots = screenshots
    }
}

/// 1 枚のスクショ（版の言語に置いた配置と、その画像）
public struct AppStoreScreenshot: Equatable, Sendable {
    /// 配置の id
    public var id: String
    /// ライブラリの画像の id
    public var imageID: String
    /// AskHub が上げた画像のファイルの MD5（参照名から読む）。ほかで上げた画像は nil
    public var checksum: String?
    /// 元の大きさの画像の URL（`imageAsset` の `templateUrl` に幅・高さ・形式を入れたもの）。処理の途中なら nil
    public var imageURL: URL?

    public init(id: String, imageID: String, checksum: String?, imageURL: URL?) {
        self.id = id
        self.imageID = imageID
        self.checksum = checksum
        self.imageURL = imageURL
    }

    /// `templateUrl`（`…/{w}x{h}bb.{f}`）に、元の幅・高さと PNG を入れる
    static func imageURL(template: String?, width: Int?, height: Int?) -> URL? {
        guard let template, let width, let height, width > 0, height > 0 else { return nil }
        let text = template.replacingOccurrences(of: "{w}", with: String(width))
            .replacingOccurrences(of: "{h}", with: String(height))
            .replacingOccurrences(of: "{f}", with: "png")
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    /// ファイルの MD5
    static func checksum(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// AskHub が上げる画像の参照名（`askhub-<ファイルの MD5>`）。App Asset Library はファイルの MD5 を返さないので、参照名に入れて、
    /// 前回と同じ画像かを画素を比べずに分かるようにし、同じ画像を言語や版をまたいで上げ直さない
    static func referenceName(checksum: String) -> String {
        "askhub-\(checksum)"
    }

    /// 参照名から MD5 を読む。AskHub の形でなければ nil
    static func checksum(referenceName: String?) -> String? {
        referenceName?.wholeMatch(of: #/askhub-([0-9a-f]{32})/#).map { String($0.1) }
    }
}

/// App Asset Library のリファレンスデータの配置グループ（`placementProfileGroups` の 1 つ）。id は文書に無いものが多く、
/// 決め打ちせずに、配置のプラットフォームと表示クラスで引く（`docs/renewal/store-screenshots.md` の「設定の組み立て」）
public struct AppStorePlacementProfileGroup: Equatable, Sendable {
    /// 配置グループ（`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など。スクショの表示サイズ）
    public var id: String
    /// 配置のプラットフォーム（`AppAssetLibraryPlacementPlatform`。`IPHONE_APP_STORE`・`IPAD_APP_STORE`・`VISION_PRO_APP_STORE` など）
    public var platform: String
    /// 表示クラス（`AppAssetLibraryDisplayClass`。`IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY`・`IPAD_13_DISPLAY` など）。無ければ nil
    public var displayClass: String?

    public init(id: String, platform: String, displayClass: String? = nil) {
        self.id = id
        self.platform = platform
        self.displayClass = displayClass
    }
}

/// ライブラリの画像
public struct AppStoreLibraryImage: Equatable, Sendable {
    public var id: String
    /// 処理の様子（`AWAITING_UPLOAD`・`UPLOAD_COMPLETE`・`PREPARE_FOR_SUBMISSION`・`APPROVED` など）
    public var state: String?
    /// 処理に失敗したわけ（`stateDetails` の誤りの文）
    public var details: String?
    /// 処理を終えた画像に Apple が合わせた仕様（処理の前は nil）
    public var specId: String?

    public init(id: String, state: String?, details: String? = nil, specId: String? = nil) {
        self.id = id
        self.state = state
        self.details = details
        self.specId = specId
    }

    /// 処理を終え、置ける。上げ終わっていない・処理の途中・失敗したものは置かない
    public var isPlaceable: Bool {
        guard let state else { return false }
        return !["AWAITING_UPLOAD", "UPLOAD_COMPLETE", "FAILED"].contains(state)
    }

    /// 処理に失敗した（Apple が受け付けなかった）
    public var isFailed: Bool { state == "FAILED" }

    /// 上げ終えて、Apple が処理している（待てば置ける）
    public var isProcessing: Bool { state == "UPLOAD_COMPLETE" }
}

/// App Store Connect のスクショの読み書き（テストでは差し替える）
public protocol AppStoreConnectScreenshots: Sendable {
    /// 版の言語ごとの掲載文の、表示サイズごとのスクショ
    func screenshotSets(of localizationID: String) async throws(AppStoreConnectError) -> [AppStoreScreenshotSet]
    /// 前回の App Store の画像を取る（App Store Connect の CDN。鍵は送らない）
    func downloadScreenshot(_ url: URL) async throws(AppStoreConnectError) -> Data
    /// 表示サイズ（配置グループ）ごとのプラットフォーム（App Asset Library のリファレンスデータ）
    func displayTypePlatforms() async throws(AppStoreConnectError) -> [String: AppStorePlatform]
    /// リファレンスデータの配置グループ（id・配置のプラットフォーム・表示クラス）
    func placementProfileGroups() async throws(AppStoreConnectError) -> [AppStorePlacementProfileGroup]
    /// アプリの App Asset Library の id
    func assetLibrary(of appID: String) async throws(AppStoreConnectError) -> String
    /// ライブラリの、参照名が `referenceName` の画像
    func libraryImages(in libraryID: String, referenceName: String) async throws(AppStoreConnectError) -> [AppStoreLibraryImage]
    /// 1 枚上げる（予約 → 送る → 終わりを伝える）。処理は待たない（何時間かかることもあるので、見回りの周で `libraryImage` を読む）。上げた画像の id を返す
    func sendImage(to libraryID: String, fileName: String, referenceName: String, data: Data) async throws(AppStoreConnectError) -> String
    /// ライブラリの 1 枚の画像の様子
    func libraryImage(_ id: String) async throws(AppStoreConnectError) -> AppStoreLibraryImage
    /// ライブラリの画像を消す（置いていないものだけ消せる）
    func deleteImage(_ id: String) async throws(AppStoreConnectError)
    /// 画像を、版の言語の表示サイズに置く。配置の id を返す
    func placeScreenshot(_ imageID: String, on localizationID: String, displayType: String) async throws(AppStoreConnectError) -> String
    /// 配置を消す（画像はライブラリに残る）
    func deletePlacement(_ id: String) async throws(AppStoreConnectError)
    /// 版の言語の表示サイズの、配置の並びを決める（`ids` がその表示サイズのすべての配置）
    func orderScreenshots(on localizationID: String, displayType: String, ids: [String]) async throws(AppStoreConnectError)
}

extension AppStoreConnectClient: AppStoreConnectScreenshots {
    /// 配置の種類（スクショ）
    static let screenshotPlacement = "APP_SCREENSHOT"

    public func screenshotSets(of localizationID: String) async throws(AppStoreConnectError) -> [AppStoreScreenshotSet] {
        try Self.checkID(localizationID)
        var query = [
            URLQueryItem(name: "filter[placementType]", value: Self.screenshotPlacement),
            URLQueryItem(name: "sort", value: "placementGroupPosition"),
            URLQueryItem(name: "include", value: "image"),
            URLQueryItem(name: "fields[appAssetLibraryPlacements]", value: "placementGroup,image"),
            URLQueryItem(name: "fields[appAssetLibraryImages]", value: "referenceName,imageAsset"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        var pages: [AppStoreConnectPlacementsResponse] = []
        for _ in 0..<10 {
            let path = "v1/appStoreVersionLocalizations/\(localizationID)/placements"
            let page = try await get(path, query: query, as: AppStoreConnectPlacementsResponse.self)
            pages.append(page)
            guard let next = page.links?.next.flatMap(URLComponents.init(string:))?.queryItems, !next.isEmpty else { break }
            query = next
        }
        return Self.screenshotSets(pages)
    }

    /// 配置の応答を、表示サイズごとの並びにする（応答の順が並びの順）。形の読めない配置は飛ばす
    static func screenshotSets(_ pages: [AppStoreConnectPlacementsResponse]) -> [AppStoreScreenshotSet] {
        let images = Dictionary(
            pages.flatMap { $0.included ?? [] }.filter { $0.type == "appAssetLibraryImages" && isID($0.id) }.map { ($0.id, $0.attributes) },
            uniquingKeysWith: { first, _ in first }
        )
        var sets: [AppStoreScreenshotSet] = []
        for item in pages.flatMap(\.data) {
            guard isID(item.id), let group = item.attributes?.placementGroup, StoreScreenshotSettings.isDisplayType(group),
                  let imageID = item.relationships?.image?.data?.id, isID(imageID) else { continue }
            let image = images[imageID].flatMap { $0 }
            let asset = image?.imageAsset
            let shot = AppStoreScreenshot(
                id: item.id,
                imageID: imageID,
                checksum: AppStoreScreenshot.checksum(referenceName: image?.referenceName),
                imageURL: AppStoreScreenshot.imageURL(template: asset?.templateUrl, width: asset?.width, height: asset?.height)
            )
            if let index = sets.firstIndex(where: { $0.displayType == group }) {
                sets[index].screenshots.append(shot)
            } else {
                sets.append(AppStoreScreenshotSet(displayType: group, screenshots: [shot]))
            }
        }
        return sets
    }

    public func downloadScreenshot(_ url: URL) async throws(AppStoreConnectError) -> Data {
        guard url.scheme == "https" else { throw .malformed("スクショの URL が https でない") }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(URLRequest(url: url))
        } catch {
            throw .unavailable(String(describing: Swift.type(of: error)))
        }
        guard (200..<300).contains(response.statusCode) else { throw .refused(status: response.statusCode, detail: "スクショの画像を取れない") }
        return data
    }

    public func displayTypePlatforms() async throws(AppStoreConnectError) -> [String: AppStorePlatform] {
        var platforms: [String: AppStorePlatform] = [:]
        for group in try await placementProfileGroups() {
            guard let platform = Self.platform(ofPlacement: group.platform) else { continue }
            platforms[group.id] = platform
        }
        return platforms
    }

    public func placementProfileGroups() async throws(AppStoreConnectError) -> [AppStorePlacementProfileGroup] {
        let query = [URLQueryItem(name: "fields[appAssetLibraryRefData]", value: "placementProfileGroups")]
        let response = try await get("v1/appAssetLibraryRefData", query: query, as: AppStoreConnectRefDataResponse.self)
        return response.data.flatMap { $0.attributes?.placementProfileGroups ?? [] }.compactMap { group in
            guard let id = group.placementProfileGroupId, StoreScreenshotSettings.isDisplayType(id),
                  let platform = group.platform, StoreScreenshotSettings.isDisplayType(platform) else { return nil }
            let displayClass = group.displayClassId.flatMap { StoreScreenshotSettings.isDisplayType($0) ? $0 : nil }
            return AppStorePlacementProfileGroup(id: id, platform: platform, displayClass: displayClass)
        }
    }

    /// 配置のプラットフォーム（`AppAssetLibraryPlacementPlatform`）を、載せる版のプラットフォームにする。
    /// Apple Watch・iMessage のスクショは iOS の版に載る
    static func platform(ofPlacement value: String) -> AppStorePlatform? {
        switch value {
        case "IPHONE_APP_STORE", "IPAD_APP_STORE", "WATCH_APP_STORE", "IMESSAGE_APP_STORE": .iOS
        case "MAC_APP_STORE": .macOS
        case "VISION_PRO_APP_STORE": .visionOS
        case "TV_APP_STORE": .tvOS
        default: nil
        }
    }

    public func assetLibrary(of appID: String) async throws(AppStoreConnectError) -> String {
        try Self.checkID(appID)
        let response = try await get("v1/apps/\(appID)/assetLibrary", query: [], as: AppStoreConnectCreated.self)
        guard Self.isID(response.data.id) else { throw .malformed("App Asset Library の id の形が違う") }
        return response.data.id
    }

    public func libraryImages(
        in libraryID: String,
        referenceName: String
    ) async throws(AppStoreConnectError) -> [AppStoreLibraryImage] {
        try Self.checkID(libraryID)
        let query = [
            URLQueryItem(name: "filter[referenceName]", value: referenceName),
            URLQueryItem(name: "fields[appAssetLibraryImages]", value: "referenceName,state,stateDetails,specId"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let response = try await get(
            "v1/appAssetLibraries/\(libraryID)/images", query: query, as: AppStoreConnectImagesResponse.self
        )
        // 絞り込みが完全一致とは文書に書かれていないので、返った参照名を比べ直す
        return response.data.compactMap { item in
            guard Self.isID(item.id), item.attributes?.referenceName == referenceName else { return nil }
            return AppStoreLibraryImage(
                id: item.id, state: item.attributes?.state, details: item.attributes?.stateDetails?.message, specId: item.attributes?.specId
            )
        }
    }

    public func libraryImage(_ id: String) async throws(AppStoreConnectError) -> AppStoreLibraryImage {
        try Self.checkID(id)
        let query = [URLQueryItem(name: "fields[appAssetLibraryImages]", value: "state,stateDetails")]
        let image = try await get(
            "v1/appAssetLibraryImages/\(id)", query: query, as: AppStoreConnectSingle<AppStoreConnectImageAttributes>.self
        )
        return AppStoreLibraryImage(id: id, state: image.data.attributes?.state, details: image.data.attributes?.stateDetails?.message)
    }

    public func sendImage(
        to libraryID: String,
        fileName: String,
        referenceName: String,
        data: Data
    ) async throws(AppStoreConnectError) -> String {
        try await sendImage(
            to: libraryID, fileName: fileName, referenceName: referenceName, data: data, category: "APP_SCREENSHOTS_AND_PREVIEWS"
        )
    }

    /// 1 枚上げる。`category` はスクショ（`APP_SCREENSHOTS_AND_PREVIEWS`）かクリエイティブアセット（`CREATIVE_ASSETS`。後から変えられない）
    func sendImage(
        to libraryID: String,
        fileName: String,
        referenceName: String,
        data: Data,
        category: String
    ) async throws(AppStoreConnectError) -> String {
        try Self.checkID(libraryID)
        let body = try Self.document(
            "appAssetLibraryImages",
            attributes: ["fileName": fileName, "fileSize": data.count, "category": category, "referenceName": referenceName],
            relationships: ["assetLibrary": ("appAssetLibraries", libraryID)]
        )
        let reply = try await send("POST", "v1/appAssetLibraryImages", body: body)
        guard let reservation = try? JSONDecoder().decode(AppStoreConnectImageReservation.self, from: reply),
              Self.isID(reservation.data.id) else {
            throw .malformed("スクショの予約の応答")
        }
        let id = reservation.data.id
        for operation in reservation.data.attributes?.uploadOperations ?? [] {
            try await put(operation, from: data)
        }
        // App Asset Library の終わりの知らせは `uploaded` だけ（MD5 は送らない。予約の大きさと比べられる）
        let commit = try Self.document("appAssetLibraryImages", id: id, attributes: ["uploaded": true])
        _ = try await send("PATCH", "v1/appAssetLibraryImages/\(id)", body: commit)
        return id
    }

    public func deleteImage(_ id: String) async throws(AppStoreConnectError) {
        try Self.checkID(id)
        _ = try await send("DELETE", "v1/appAssetLibraryImages/\(id)")
    }

    public func placeScreenshot(
        _ imageID: String,
        on localizationID: String,
        displayType: String
    ) async throws(AppStoreConnectError) -> String {
        try Self.checkID(imageID)
        try Self.checkID(localizationID)
        guard StoreScreenshotSettings.isDisplayType(displayType) else { throw .malformed("表示サイズの形が違う") }
        let body = try Self.document(
            "appAssetLibraryPlacements",
            attributes: ["placementType": Self.screenshotPlacement, "placementGroup": displayType],
            relationships: [
                "image": ("appAssetLibraryImages", imageID),
                "appStoreVersionLocalization": ("appStoreVersionLocalizations", localizationID)
            ]
        )
        let data = try await send("POST", "v1/appAssetLibraryPlacements", body: body)
        guard let created = try? JSONDecoder().decode(AppStoreConnectCreated.self, from: data), Self.isID(created.data.id) else {
            throw .malformed("作ったスクショの配置の応答")
        }
        return created.data.id
    }

    public func deletePlacement(_ id: String) async throws(AppStoreConnectError) {
        try Self.checkID(id)
        _ = try await send("DELETE", "v1/appAssetLibraryPlacements/\(id)")
    }

    public func orderScreenshots(on localizationID: String, displayType: String, ids: [String]) async throws(AppStoreConnectError) {
        try Self.checkID(localizationID)
        guard StoreScreenshotSettings.isDisplayType(displayType) else { throw .malformed("表示サイズの形が違う") }
        for id in ids { try Self.checkID(id) }
        let relationships: [String: Any] = [
            "orderedPlacements": ["data": ids.map { ["type": "appAssetLibraryPlacements", "id": $0] }],
            "appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": localizationID]]
        ]
        let body = try Self.json([
            "data": [
                "type": "appAssetLibraryPlacementOrderingRequests",
                "attributes": ["placementGroup": displayType],
                "relationships": relationships
            ]
        ])
        _ = try await send("POST", "v1/appAssetLibraryPlacementOrderingRequests", body: body)
    }

    /// 予約が示した URL に、示された範囲を送る（鍵は送らない。URL は時間を限った署名つき）
    private func put(_ operation: AppStoreConnectImageReservation.Operation, from data: Data) async throws(AppStoreConnectError) {
        guard let url = URL(string: operation.url), url.scheme == "https", operation.offset >= 0, operation.length > 0,
              operation.offset + operation.length <= data.count else {
            throw .malformed("スクショを送る先の形が違う")
        }
        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        for header in operation.requestHeaders ?? [] { request.setValue(header.value, forHTTPHeaderField: header.name) }
        request.httpBody = data.subdata(in: operation.offset..<(operation.offset + operation.length))
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
        } catch {
            throw .unavailable(String(describing: Swift.type(of: error)))
        }
        guard (200..<300).contains(response.statusCode) else { throw .refused(status: response.statusCode, detail: "スクショを送れない") }
    }
}
