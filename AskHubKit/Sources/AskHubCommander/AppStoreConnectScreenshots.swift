import AskHubProtocol
import CryptoKit
import Foundation

// App Store Connect のスクショ（appScreenshotSets / appScreenshots）。API 4.5 で非推奨になり App Asset Library に移ったが、
// iPhone Duo のほかの表示サイズは今の API で扱える（`docs/renewal/release.md` の「スクショ」）。書き込みは人が審査に出したときだけ

/// 版の 1 つの言語の、1 つの表示サイズのスクショの組
public struct AppStoreScreenshotSet: Equatable, Sendable {
    public var id: String
    /// 表示サイズ（`APP_IPHONE_67` など。知らない値もそのまま持つ）
    public var displayType: String
    /// 並びの順のスクショ
    public var screenshots: [AppStoreScreenshot]

    public init(id: String, displayType: String, screenshots: [AppStoreScreenshot]) {
        self.id = id
        self.displayType = displayType
        self.screenshots = screenshots
    }
}

/// 1 枚のスクショ
public struct AppStoreScreenshot: Equatable, Sendable {
    public var id: String
    /// 上げたファイルの MD5（`sourceFileChecksum`）
    public var checksum: String?
    /// 元の大きさの画像の URL（`imageAsset` の `templateUrl` に幅・高さ・形式を入れたもの）。処理の途中なら nil
    public var imageURL: URL?

    public init(id: String, checksum: String?, imageURL: URL?) {
        self.id = id
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
}

/// App Store Connect のスクショの読み書き（テストでは差し替える）
public protocol AppStoreConnectScreenshots: Sendable {
    /// 版の言語ごとの掲載文の、表示サイズごとのスクショの組
    func screenshotSets(of localizationID: String) async throws(AppStoreConnectError) -> [AppStoreScreenshotSet]
    /// 前回の App Store の画像を取る（App Store Connect の CDN。鍵は送らない）
    func downloadScreenshot(_ url: URL) async throws(AppStoreConnectError) -> Data
    func createScreenshotSet(of localizationID: String, displayType: String) async throws(AppStoreConnectError) -> AppStoreScreenshotSet
    /// 1 枚上げる（予約 → 送る → 終わりを伝える → 処理を待つ）。上げたスクショの id を返す
    func uploadScreenshot(to setID: String, fileName: String, data: Data) async throws(AppStoreConnectError) -> String
    func deleteScreenshot(_ id: String) async throws(AppStoreConnectError)
    /// 組のスクショの並びを決める（並べたものだけが組に残る）
    func orderScreenshots(of setID: String, ids: [String]) async throws(AppStoreConnectError)
}

extension AppStoreScreenshot {
    /// ファイルの MD5（`sourceFileChecksum` と比べる）
    static func checksum(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct AppStoreConnectScreenshotLinks: Decodable {
    var data: [AppStoreConnectLink]?
}

struct AppStoreConnectScreenshotSetsResponse: Decodable {
    struct Relationships: Decodable {
        var appScreenshots: AppStoreConnectScreenshotLinks?
    }

    struct Item: Decodable {
        var id: String
        var attributes: SetAttributes?
        var relationships: Relationships?
    }

    struct SetAttributes: Decodable {
        var screenshotDisplayType: String?
    }

    struct ImageAsset: Decodable {
        var templateUrl: String?
        var width: Int?
        var height: Int?
    }

    struct ScreenshotAttributes: Decodable {
        var sourceFileChecksum: String?
        var imageAsset: ImageAsset?
    }

    var data: [Item]
    var included: [AppStoreConnectResource<ScreenshotAttributes>]?
}

struct AppStoreConnectScreenshotReservation: Decodable {
    struct Header: Decodable {
        var name: String
        var value: String
    }

    struct Operation: Decodable {
        var method: String
        var url: String
        var length: Int
        var offset: Int
        var requestHeaders: [Header]?
    }

    struct State: Decodable {
        var state: String?
    }

    struct Attributes: Decodable {
        var uploadOperations: [Operation]?
        var assetDeliveryState: State?
    }

    struct Resource: Decodable {
        var id: String
        var attributes: Attributes?
    }

    var data: Resource
}

extension AppStoreConnectClient: AppStoreConnectScreenshots {
    public func screenshotSets(of localizationID: String) async throws(AppStoreConnectError) -> [AppStoreScreenshotSet] {
        try Self.checkID(localizationID)
        let query = [
            URLQueryItem(name: "fields[appScreenshotSets]", value: "screenshotDisplayType,appScreenshots"),
            URLQueryItem(name: "include", value: "appScreenshots"),
            URLQueryItem(name: "fields[appScreenshots]", value: "sourceFileChecksum,imageAsset"),
            URLQueryItem(name: "limit[appScreenshots]", value: String(StoreScreenshotSettings.maximumShots)),
            URLQueryItem(name: "limit", value: "50")
        ]
        let path = "v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets"
        let response = try await get(path, query: query, as: AppStoreConnectScreenshotSetsResponse.self)
        let shots = Dictionary(
            (response.included ?? []).filter { $0.type == "appScreenshots" && Self.isID($0.id) }.map { ($0.id, $0.attributes) },
            uniquingKeysWith: { first, _ in first }
        )
        return response.data.compactMap { item in
            guard Self.isID(item.id), let type = item.attributes?.screenshotDisplayType else { return nil }
            let screenshots = (item.relationships?.appScreenshots?.data ?? []).compactMap { link -> AppStoreScreenshot? in
                guard Self.isID(link.id) else { return nil }
                let attributes = shots[link.id].flatMap { $0 }
                let asset = attributes?.imageAsset
                return AppStoreScreenshot(
                    id: link.id,
                    checksum: attributes?.sourceFileChecksum,
                    imageURL: AppStoreScreenshot.imageURL(template: asset?.templateUrl, width: asset?.width, height: asset?.height)
                )
            }
            return AppStoreScreenshotSet(id: item.id, displayType: type, screenshots: screenshots)
        }
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

    public func createScreenshotSet(
        of localizationID: String,
        displayType: String
    ) async throws(AppStoreConnectError) -> AppStoreScreenshotSet {
        try Self.checkID(localizationID)
        guard StoreScreenshotSettings.isDisplayType(displayType) else { throw .malformed("表示サイズの形が違う") }
        let body = try Self.document(
            "appScreenshotSets",
            attributes: ["screenshotDisplayType": displayType],
            relationships: ["appStoreVersionLocalization": ("appStoreVersionLocalizations", localizationID)]
        )
        let data = try await send("POST", "v1/appScreenshotSets", body: body)
        guard let created = try? JSONDecoder().decode(AppStoreConnectCreated.self, from: data), Self.isID(created.data.id) else {
            throw .malformed("作ったスクショの組の応答")
        }
        return AppStoreScreenshotSet(id: created.data.id, displayType: displayType, screenshots: [])
    }

    public func uploadScreenshot(to setID: String, fileName: String, data: Data) async throws(AppStoreConnectError) -> String {
        try Self.checkID(setID)
        let body = try Self.document(
            "appScreenshots",
            attributes: ["fileName": fileName, "fileSize": data.count],
            relationships: ["appScreenshotSet": ("appScreenshotSets", setID)]
        )
        let reply = try await send("POST", "v1/appScreenshots", body: body)
        guard let reservation = try? JSONDecoder().decode(AppStoreConnectScreenshotReservation.self, from: reply),
              Self.isID(reservation.data.id) else {
            throw .malformed("スクショの予約の応答")
        }
        let id = reservation.data.id
        for operation in reservation.data.attributes?.uploadOperations ?? [] {
            try await put(operation, from: data)
        }
        let commit = try Self.document(
            "appScreenshots", id: id, attributes: ["uploaded": true, "sourceFileChecksum": AppStoreScreenshot.checksum(of: data)]
        )
        _ = try await send("PATCH", "v1/appScreenshots/\(id)", body: commit)
        try await waitForDelivery(of: id)
        return id
    }

    public func deleteScreenshot(_ id: String) async throws(AppStoreConnectError) {
        try Self.checkID(id)
        _ = try await send("DELETE", "v1/appScreenshots/\(id)")
    }

    public func orderScreenshots(of setID: String, ids: [String]) async throws(AppStoreConnectError) {
        try Self.checkID(setID)
        for id in ids { try Self.checkID(id) }
        let body: Data
        do {
            let links = ids.map { ["type": "appScreenshots", "id": $0] }
            body = try JSONSerialization.data(withJSONObject: ["data": links], options: [.sortedKeys])
        } catch {
            throw .malformed("並びの本文を作れない")
        }
        _ = try await send("PATCH", "v1/appScreenshotSets/\(setID)/relationships/appScreenshots", body: body)
    }

    /// 予約が示した URL に、示された範囲を送る（鍵は送らない。URL は時間を限った署名つき）
    private func put(_ operation: AppStoreConnectScreenshotReservation.Operation, from data: Data) async throws(AppStoreConnectError) {
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

    /// 上げたスクショの処理が終わる（`COMPLETE`）まで待つ。失敗（`FAILED`）は断りにする。待ちすぎたら、待てば直るものとして投げる
    private func waitForDelivery(of id: String) async throws(AppStoreConnectError) {
        let query = [URLQueryItem(name: "fields[appScreenshots]", value: "assetDeliveryState")]
        for attempt in 0..<30 {
            let state = try await get("v1/appScreenshots/\(id)", query: query, as: AppStoreConnectScreenshotReservation.self)
            switch state.data.attributes?.assetDeliveryState?.state {
            case "COMPLETE":
                return
            case "FAILED":
                throw .refused(status: 409, detail: "上げたスクショの処理に失敗した")
            default:
                try? await Task.sleep(for: .seconds(attempt < 5 ? 2 : 5))
            }
        }
        throw .unavailable("上げたスクショの処理が終わらない")
    }
}
