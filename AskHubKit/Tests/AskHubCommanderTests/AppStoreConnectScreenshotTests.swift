@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

/// App Store Connect のスクショ（App Asset Library）の要求と応答の読み方
struct AppStoreConnectScreenshotTests {
    let base = AppStoreConnectTests()

    func query(_ request: URLRequest?) -> [String: String] {
        let items = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object?["data"] as? [String: Any])
    }

    @Test func readsPlacementsAsScreenshotSetsInOrder() async throws {
        let checksum = String(repeating: "a", count: 32)
        let page1 = #"{"data":["#
            + #"{"type":"appAssetLibraryPlacements","id":"p1","attributes":{"placementGroup":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"},"#
            + #""relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":"img-1"}}}},"#
            + #"{"type":"appAssetLibraryPlacements","id":"p2","attributes":{"placementGroup":"IPHONE_DUO_PROFILE"},"#
            + #""relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":"img-2"}}}}],"#
            + #""included":[{"type":"appAssetLibraryImages","id":"img-1","attributes":{"referenceName":"askhub-\#(checksum)","#
            + #""imageAsset":{"templateUrl":"https://is1-ssl.mzstatic.com/a/{w}x{h}bb.{f}","width":1320,"height":2868}}},"#
            + #"{"type":"appAssetLibraryImages","id":"img-2","attributes":{"referenceName":"Home","imageAsset":null}}],"#
            + #""links":{"next":"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/l-ja/placements?cursor=Mg&limit=200"}}"#
        let page2 = #"{"data":[{"type":"appAssetLibraryPlacements","id":"p3","#
            + #""attributes":{"placementGroup":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"},"#
            + #""relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":"img-3"}}}}]}"#
        let transport = StubTransport([.json(200, page1), .json(200, page2)])
        let sets = try await base.client(transport).screenshotSets(of: "l-ja")
        #expect(sets.map(\.displayType) == ["IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", "IPHONE_DUO_PROFILE"])
        // 応答の順（placementGroupPosition で並べたもの）が並びの順。次のページも読む
        #expect(sets[0].screenshots.map(\.id) == ["p1", "p3"])
        #expect(sets[0].screenshots[0] == AppStoreScreenshot(
            id: "p1", imageID: "img-1", checksum: checksum, imageURL: URL(string: "https://is1-ssl.mzstatic.com/a/1320x2868bb.png")
        ))
        // AskHub の参照名でない画像は MD5 が分からない
        #expect(sets[1].screenshots == [AppStoreScreenshot(id: "p2", imageID: "img-2", checksum: nil, imageURL: nil)])
        let first = query(transport.requests.first)
        #expect(transport.requests.first?.url?.path == "/v1/appStoreVersionLocalizations/l-ja/placements")
        #expect(first["filter[placementType]"] == "APP_SCREENSHOT" && first["sort"] == "placementGroupPosition")
        #expect(first["include"] == "image")
        #expect(query(transport.requests.last)["cursor"] == "Mg")
    }

    @Test func uploadsImageWithoutChecksumAndWaitsForProcessing() async throws {
        let data = Data(repeating: 7, count: 10)
        let reservation = #"{"data":{"type":"appAssetLibraryImages","id":"img-9","attributes":{"state":"AWAITING_UPLOAD","#
            + #""uploadOperations":[{"method":"PUT","url":"https://store-030.blobstore.apple.com/up","length":10,"offset":0,"#
            + #""requestHeaders":[{"name":"Content-Type","value":"image/png"}]}]}}}"#
        let transport = StubTransport([
            .json(201, reservation),
            .json(200, ""),
            .json(200, #"{"data":{"type":"appAssetLibraryImages","id":"img-9"}}"#),
            .json(200, #"{"data":{"type":"appAssetLibraryImages","id":"img-9","attributes":{"state":"PREPARE_FOR_SUBMISSION"}}}"#)
        ])
        let id = try await base.client(transport).uploadImage(
            to: "lib-1", fileName: "IPHONE_DUO_PROFILE-ja-1.png", referenceName: "askhub-\(String(repeating: "b", count: 32))", data: data
        )
        #expect(id == "img-9")
        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "POST /v1/appAssetLibraryImages", "PUT /up", "PATCH /v1/appAssetLibraryImages/img-9", "GET /v1/appAssetLibraryImages/img-9"
        ])
        let reserve = try body(requests[0])
        let attributes = try #require(reserve["attributes"] as? [String: Any])
        #expect(attributes["category"] as? String == "APP_SCREENSHOTS_AND_PREVIEWS" && attributes["fileSize"] as? Int == 10)
        #expect(attributes["referenceName"] as? String == "askhub-\(String(repeating: "b", count: 32))")
        // 送る先には鍵を付けない
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil && requests[1].httpBody == data)
        // 終わりの知らせは uploaded だけ（App Asset Library に MD5 の欄は無い）
        #expect(try body(requests[2])["attributes"] as? [String: Bool] == ["uploaded": true])
    }

    @Test func refusesAndDeletesImageWhenProcessingFails() async throws {
        let reservation = #"{"data":{"type":"appAssetLibraryImages","id":"img-9","attributes":{"uploadOperations":[]}}}"#
        let transport = StubTransport([
            .json(201, reservation),
            .json(200, #"{"data":{"type":"appAssetLibraryImages","id":"img-9"}}"#),
            .json(200, #"{"data":{"type":"appAssetLibraryImages","id":"img-9","attributes":{"state":"FAILED"}}}"#),
            .json(204, "")
        ])
        await #expect(throws: AppStoreConnectError.self) {
            try await base.client(transport).uploadImage(to: "lib-1", fileName: "a.png", referenceName: "a", data: Data([1]))
        }
        #expect(transport.requests.last?.httpMethod == "DELETE" && transport.requests.last?.url?.path == "/v1/appAssetLibraryImages/img-9")
    }

    @Test func placesAndOrdersScreenshots() async throws {
        let transport = StubTransport([
            .json(201, #"{"data":{"type":"appAssetLibraryPlacements","id":"p-new"}}"#),
            .json(201, #"{"data":{"type":"appAssetLibraryPlacementOrderingRequests","id":"o-1"}}"#)
        ])
        let client = base.client(transport)
        #expect(try await client.placeScreenshot("img-1", on: "l-ja", displayType: "IPHONE_DUO_PROFILE") == "p-new")
        try await client.orderScreenshots(on: "l-ja", displayType: "IPHONE_DUO_PROFILE", ids: ["p-1", "p-new"])
        let place = try body(transport.requests[0])
        #expect(place["attributes"] as? [String: String] == ["placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_DUO_PROFILE"])
        let relationships = try #require(place["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["image"]?["data"] == ["type": "appAssetLibraryImages", "id": "img-1"])
        #expect(relationships["appStoreVersionLocalization"]?["data"] == ["type": "appStoreVersionLocalizations", "id": "l-ja"])
        #expect(transport.requests[1].url?.path == "/v1/appAssetLibraryPlacementOrderingRequests")
        let order = try body(transport.requests[1])
        #expect(order["attributes"] as? [String: String] == ["placementGroup": "IPHONE_DUO_PROFILE"])
        let ordered = (order["relationships"] as? [String: Any])?["orderedPlacements"] as? [String: [[String: String]]]
        #expect(ordered?["data"]?.map { $0["id"] } == ["p-1", "p-new"])
        // 表示サイズの形が違えば送らない
        await #expect(throws: AppStoreConnectError.self) {
            try await client.orderScreenshots(on: "l-ja", displayType: "bad group", ids: [])
        }
        #expect(transport.requests.count == 2)
    }

    @Test func readsPlatformsOfDisplayTypesFromReferenceData() async throws {
        let body = #"{"data":[{"type":"appAssetLibraryRefData","id":"1","attributes":{"placementProfileGroups":["#
            + #"{"placementProfileGroupId":"IPHONE_DUO_PROFILE","platform":"IPHONE_APP_STORE","displayClassId":"IPHONE_DUO"},"#
            + #"{"placementProfileGroupId":"IPAD_13_PROFILE","platform":"IPAD_APP_STORE"},"#
            + #"{"placementProfileGroupId":"MAC_PROFILE","platform":"MAC_APP_STORE","displayClassId":"DEFAULT"},"#
            + #"{"placementProfileGroupId":"FUTURE_PROFILE","platform":"FUTURE_APP_STORE"}]}}]}"#
        let transport = StubTransport([.json(200, body)])
        let platforms = try await base.client(transport).displayTypePlatforms()
        #expect(platforms == ["IPHONE_DUO_PROFILE": .iOS, "IPAD_13_PROFILE": .iOS, "MAC_PROFILE": .macOS])
        #expect(query(transport.requests.first)["fields[appAssetLibraryRefData]"] == "placementProfileGroups")
    }

    @Test func findsLibraryImagesByExactReferenceName() async throws {
        let name = "askhub-\(String(repeating: "c", count: 32))"
        let transport = StubTransport([
            .json(200, #"{"data":{"type":"appAssetLibraries","id":"lib-1"}}"#),
            .json(200, #"{"data":[{"type":"appAssetLibraryImages","id":"img-1","#
                + #""attributes":{"referenceName":"\#(name)","state":"APPROVED"}},"#
                + #"{"type":"appAssetLibraryImages","id":"img-2","attributes":{"referenceName":"\#(name)-old","state":"APPROVED"}}]}"#)
        ])
        let client = base.client(transport)
        let library = try await client.assetLibrary(of: "6740000001")
        #expect(library == "lib-1" && transport.requests[0].url?.path == "/v1/apps/6740000001/assetLibrary")
        #expect(try await client.libraryImages(in: library, referenceName: name) == [AppStoreLibraryImage(id: "img-1", state: "APPROVED")])
        #expect(query(transport.requests[1])["filter[referenceName]"] == name)
    }

    @Test func readsChecksumOnlyFromAskHubReferenceNames() {
        let checksum = AppStoreScreenshot.checksum(of: Data("x".utf8))
        #expect(AppStoreScreenshot.checksum(referenceName: AppStoreScreenshot.referenceName(checksum: checksum)) == checksum)
        #expect(AppStoreScreenshot.checksum(referenceName: "Home screen") == nil)
        #expect(AppStoreScreenshot.checksum(referenceName: "askhub-XYZ") == nil)
        #expect(!AppStoreLibraryImage(id: "a", state: "UPLOAD_COMPLETE").isPlaceable)
        #expect(AppStoreLibraryImage(id: "a", state: "APPROVED").isPlaceable)
    }
}
