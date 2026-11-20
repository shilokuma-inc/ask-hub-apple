@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 新しいアプリを載せる準備の App Store Connect の API（Bundle ID・準備の様子・決まった値）の要求と応答
struct AppStoreConnectListingTests {
    private func client(_ transport: StubTransport) -> AppStoreConnectClient {
        AppStoreConnectTests().client(transport)
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url else { return [:] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func object(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func readsRegisteredBundleIDsExactly() async throws {
        let body = """
            {"data":[
              {"type":"bundleIds","id":"B1","attributes":{"identifier":"jp.shilokuma.NewApp"}},
              {"type":"bundleIds","id":"B2","attributes":{"identifier":"jp.shilokuma.NewApp.Widget"}}
            ]}
            """
        let transport = StubTransport([.json(200, body)])
        let registered = try await client(transport).registeredBundleIDs(["jp.shilokuma.NewApp", "jp.shilokuma.Other"])
        #expect(registered == ["jp.shilokuma.NewApp"])
        #expect(transport.requests.first?.url?.path == "/v1/bundleIds")
        #expect(query(transport.requests.first)["filter[identifier]"] == "jp.shilokuma.NewApp,jp.shilokuma.Other")
    }

    @Test func registersBundleID() async throws {
        let transport = StubTransport([.json(201, #"{"data":{"type":"bundleIds","id":"B1"}}"#)])
        try await client(transport).registerBundleID("jp.shilokuma.NewApp", name: "AskHub jp shilokuma NewApp", platform: .universal)
        let request = transport.requests.first
        #expect(request?.httpMethod == "POST" && request?.url?.path == "/v1/bundleIds")
        let data = try #require(try object(request)["data"] as? [String: Any])
        #expect(data["type"] as? String == "bundleIds")
        let attributes = try #require(data["attributes"] as? [String: String])
        #expect(attributes == ["identifier": "jp.shilokuma.NewApp", "name": "AskHub jp shilokuma NewApp", "platform": "UNIVERSAL"])
    }

    @Test func readsSetupStateOfNewApp() async throws {
        let app = #"{"data":{"type":"apps","id":"6740000002","attributes":{"primaryLocale":"ja","contentRightsDeclaration":null}}}"#
        let infos = """
            {"data":[
              {"type":"appInfos","id":"info-1","attributes":{"state":"PREPARE_FOR_SUBMISSION"},
               "relationships":{"primaryCategory":{"data":null},
                                "ageRatingDeclaration":{"data":{"type":"ageRatingDeclarations","id":"age-1"}}}}
            ],
            "included":[
              {"type":"ageRatingDeclarations","id":"age-1","attributes":{"violenceRealistic":"NONE","gambling":false,"advertising":null}}
            ]}
            """
        let localizations = """
            {"data":[
              {"type":"appInfoLocalizations","id":"loc-ja","attributes":{"locale":"ja","privacyPolicyUrl":"https://example.com/privacy"}},
              {"type":"appInfoLocalizations","id":"loc-en","attributes":{"locale":"en-US","privacyPolicyUrl":null}}
            ]}
            """
        let transport = StubTransport([
            .json(200, app),
            .json(200, infos),
            .json(200, localizations),
            .json(404, #"{"errors":[{"status":"404"}]}"#),
            .json(200, #"{"data":{"type":"appAvailabilities","id":"avail-1","attributes":{"availableInNewTerritories":true}}}"#)
        ])
        let state = try await client(transport).setupState(of: "6740000002")
        #expect(state.primaryLocale == "ja")
        #expect(state.contentRights == nil)
        #expect(state.appInfoID == "info-1" && state.primaryCategory == nil)
        #expect(state.infoLocalizations.map(\.locale) == ["ja", "en-US"])
        #expect(state.infoLocalizations.last?.privacyPolicyUrl == nil)
        // 答えた 2 つ（violenceRealistic・gambling）のほかは、答えていない
        let unanswered = try #require(state.unansweredAgeRatings)
        #expect(!unanswered.contains("violenceRealistic") && !unanswered.contains("gambling"))
        #expect(unanswered.contains("advertising") && unanswered.contains("contests"))
        #expect(state.hasPrice == false && state.hasAvailability == true)
        #expect(transport.requests.map { $0.url?.path ?? "" } == [
            "/v1/apps/6740000002",
            "/v1/apps/6740000002/appInfos",
            "/v1/appInfos/info-1/appInfoLocalizations",
            "/v1/apps/6740000002/appPriceSchedule",
            "/v1/apps/6740000002/appAvailabilityV2"
        ])
        #expect(query(transport.requests[1])["include"] == "ageRatingDeclaration")
    }

    @Test func setsFreePriceWithZeroPricePointOfBaseTerritory() async throws {
        let firstPage = """
            {"data":[{"type":"appPricePoints","id":"pp-099","attributes":{"customerPrice":"0.99"}}],
             "links":{"self":"x","next":"https://api.appstoreconnect.apple.com/v1/apps/6740000002/appPricePoints?cursor=AB&limit=200&filter%5Bterritory%5D=USA"}}
            """
        let secondPage = #"{"data":[{"type":"appPricePoints","id":"pp-free=","attributes":{"customerPrice":"0.0"}}],"links":{"self":"y"}}"#
        let created = #"{"data":{"type":"appPriceSchedules","id":"s1"}}"#
        let transport = StubTransport([.json(200, firstPage), .json(200, secondPage), .json(201, created)])
        try await client(transport).setFreePrice(of: "6740000002")
        #expect(query(transport.requests[0])["filter[territory]"] == "USA")
        #expect(query(transport.requests[1])["cursor"] == "AB")
        let post = transport.requests[2]
        #expect(post.httpMethod == "POST" && post.url?.path == "/v1/appPriceSchedules")
        let body = try object(post)
        let data = try #require(body["data"] as? [String: Any])
        let relationships = try #require(data["relationships"] as? [String: Any])
        let base = try #require((relationships["baseTerritory"] as? [String: Any])?["data"] as? [String: String])
        #expect(base == ["type": "territories", "id": "USA"])
        let included = try #require(body["included"] as? [[String: Any]])
        let priceRelationships = try #require(included.first?["relationships"] as? [String: Any])
        let point = try #require((priceRelationships["appPricePoint"] as? [String: Any])?["data"] as? [String: String])
        #expect(point == ["type": "appPricePoints", "id": "pp-free="])
        #expect(included.first?["type"] as? String == "appPrices")
    }

    @Test func refusesWhenNoFreePricePoint() async throws {
        let page = #"{"data":[{"type":"appPricePoints","id":"pp-099","attributes":{"customerPrice":"0.99"}}]}"#
        let transport = StubTransport([.json(200, page)])
        await #expect(throws: AppStoreConnectError.self) { try await client(transport).setFreePrice(of: "6740000002") }
        #expect(transport.requests.count == 1)
    }

    @Test func makesAppAvailableInEveryTerritory() async throws {
        let territories = """
            {"data":[{"type":"territories","id":"JPN","attributes":{"currency":"JPY"}},
                     {"type":"territories","id":"USA","attributes":{"currency":"USD"}},
                     {"type":"territories","id":"bad/1"}]}
            """
        let transport = StubTransport([.json(200, territories), .json(201, #"{"data":{"type":"appAvailabilities","id":"a1"}}"#)])
        try await client(transport).setAvailableEverywhere(of: "6740000002")
        let post = transport.requests[1]
        #expect(post.httpMethod == "POST" && post.url?.path == "/v2/appAvailabilities")
        let body = try object(post)
        let data = try #require(body["data"] as? [String: Any])
        #expect((data["attributes"] as? [String: Bool]) == ["availableInNewTerritories": true])
        let included = try #require(body["included"] as? [[String: Any]])
        #expect(included.compactMap { $0["id"] as? String } == ["${JPN}", "${USA}"])
        #expect(included.allSatisfy { ($0["attributes"] as? [String: Bool]) == ["available": true] })
    }

    @Test func writesContentRightsCategoryAndPrivacyPolicy() async throws {
        let transport = StubTransport([.json(200, "{}"), .json(200, "{}"), .json(200, "{}")])
        let client = client(transport)
        try await client.setContentRights(.doesNotUseThirdPartyContent, of: "6740000002")
        try await client.setCategory("GAMES", subcategory: "GAMES_PUZZLE", appInfoID: "info-1")
        try await client.setPrivacyPolicyURL("https://example.com/privacy", localizationID: "loc-en")
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PATCH /v1/apps/6740000002", "PATCH /v1/appInfos/info-1", "PATCH /v1/appInfoLocalizations/loc-en"
        ])
        let rights = try #require(try object(transport.requests[0])["data"] as? [String: Any])
        #expect((rights["attributes"] as? [String: String]) == ["contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"])
        let category = try #require(try object(transport.requests[1])["data"] as? [String: Any])
        let relationships = try #require(category["relationships"] as? [String: [String: [String: String]]])
        #expect(relationships["primaryCategory"]?["data"] == ["type": "appCategories", "id": "GAMES"])
        #expect(relationships["primarySubcategoryOne"]?["data"] == ["type": "appCategories", "id": "GAMES_PUZZLE"])
        // 形の違う値は送らない
        await #expect(throws: AppStoreConnectError.self) {
            try await client.setPrivacyPolicyURL("http://example.com", localizationID: "loc-en")
        }
        #expect(transport.requests.count == 3)
    }
}
