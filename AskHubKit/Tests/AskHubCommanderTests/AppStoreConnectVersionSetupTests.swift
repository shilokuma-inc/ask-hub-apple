@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 初めての版の項目の App Store Connect の API（著作権表示・サポート URL とマーケティング URL・App Review の連絡先）の要求と応答
struct AppStoreConnectVersionSetupTests {
    private func client(_ transport: StubTransport) -> AppStoreConnectClient {
        AppStoreConnectTests().client(transport)
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url else { return [:] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func attributes(_ request: URLRequest?) throws -> [String: String] {
        let data = try #require(request?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try #require(object["data"] as? [String: Any])
        return try #require(resource["attributes"] as? [String: String])
    }

    @Test func readsVersionSetupWithoutKeepingContactValues() async throws {
        let version = #"{"data":{"type":"appStoreVersions","id":"v-1","attributes":{"copyright":""}}}"#
        let localizations = """
            {"data":[
              {"type":"appStoreVersionLocalizations","id":"l-ja","attributes":{"locale":"ja","supportUrl":"https://example.com/support","marketingUrl":null}},
              {"type":"appStoreVersionLocalizations","id":"l-en","attributes":{"locale":"en-US","supportUrl":"","marketingUrl":"https://example.com"}}
            ]}
            """
        let detail = """
            {"data":{"type":"appStoreReviewDetails","id":"r-1",
                     "attributes":{"contactFirstName":"Taro","contactLastName":"Yamada","contactPhone":" ","contactEmail":null}}}
            """
        let transport = StubTransport([.json(200, version), .json(200, localizations), .json(200, detail)])
        let state = try await client(transport).versionSetupState(of: "v-1")
        // 空の著作権表示・サポート URL は、書いていないものとして読む
        #expect(state.copyright == nil)
        #expect(state.localizations == [
            .init(id: "l-ja", locale: "ja", supportUrl: "https://example.com/support"),
            .init(id: "l-en", locale: "en-US", marketingUrl: "https://example.com")
        ])
        // 連絡先は、入れていない欄だけを返す（入れた名前は返さない）
        #expect(state.missingReviewContact == [.phone, .email])
        #expect(state.reviewDetailID == "r-1")
        #expect(transport.requests.map { $0.url?.path ?? "" } == [
            "/v1/appStoreVersions/v-1",
            "/v1/appStoreVersions/v-1/appStoreVersionLocalizations",
            "/v1/appStoreVersions/v-1/appStoreReviewDetail"
        ])
        #expect(query(transport.requests[0])["fields[appStoreVersions]"] == "copyright")
        // パスワードやメモは求めない
        let fields = query(transport.requests[2])["fields[appStoreReviewDetails]"]
        #expect(fields == "contactFirstName,contactLastName,contactPhone,contactEmail")
    }

    @Test func treatsMissingReviewDetailAsNoContact() async throws {
        let transport = StubTransport([
            .json(200, #"{"data":{"type":"appStoreVersions","id":"v-1","attributes":{"copyright":"2026 Shilokuma Inc."}}}"#),
            .json(200, #"{"data":[]}"#),
            .json(404, #"{"errors":[{"status":"404"}]}"#)
        ])
        let state = try await client(transport).versionSetupState(of: "v-1")
        #expect(state.copyright == "2026 Shilokuma Inc.")
        #expect(state.localizations.isEmpty)
        #expect(state.missingReviewContact == ReviewContactField.allCases)
    }

    @Test func writesCopyrightAndURLs() async throws {
        let transport = StubTransport([.json(200, "{}"), .json(200, "{}"), .json(200, "{}")])
        let client = client(transport)
        try await client.setCopyright("2026 Shilokuma Inc.", versionID: "v-1")
        try await client.setVersionURLs(support: "https://example.com/support", marketing: nil, localizationID: "l-ja")
        try await client.setVersionURLs(support: nil, marketing: "https://example.com", localizationID: "l-en")
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "PATCH /v1/appStoreVersions/v-1",
            "PATCH /v1/appStoreVersionLocalizations/l-ja",
            "PATCH /v1/appStoreVersionLocalizations/l-en"
        ])
        #expect(try attributes(transport.requests[0]) == ["copyright": "2026 Shilokuma Inc."])
        // nil の欄は送らない（App Store Connect で書いた値を消さない）
        #expect(try attributes(transport.requests[1]) == ["supportUrl": "https://example.com/support"])
        #expect(try attributes(transport.requests[2]) == ["marketingUrl": "https://example.com"])
    }

    @Test func refusesMalformedValuesBeforeSending() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        await #expect(throws: AppStoreConnectError.self) { try await client.setCopyright("2026\nShilokuma", versionID: "v-1") }
        await #expect(throws: AppStoreConnectError.self) {
            try await client.setVersionURLs(support: "http://example.com", marketing: nil, localizationID: "l-ja")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func readsAndWritesReviewContactWithoutShowingValues() async throws {
        let detail = """
            {"data":{"type":"appStoreReviewDetails","id":"r-9",
                     "attributes":{"contactFirstName":"Taro","contactLastName":"Yamada",
                                   "contactPhone":"+81 90 0000 0000","contactEmail":"taro@example.com"}}}
            """
        let created = #"{"data":{"type":"appStoreReviewDetails","id":"r-new"}}"#
        let transport = StubTransport([.json(200, detail), .json(200, "{}"), .json(201, created)])
        let client = client(transport)
        let found = try #require(try await client.reviewContact(of: "v-9"))
        #expect(found.detailID == "r-9" && found.contact.isComplete)
        // 文字列にしても値を出さない（ログに混ざらないように）
        #expect(!"\(found.contact)".contains("Taro") && !String(reflecting: found.contact).contains("taro@example.com"))
        try await client.writeReviewContact(found.contact, fields: [.phone], detailID: "r-1", versionID: "v-1")
        try await client.writeReviewContact(found.contact, fields: ReviewContactField.allCases, detailID: nil, versionID: "v-2")
        #expect(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /v1/appStoreVersions/v-9/appStoreReviewDetail",
            "PATCH /v1/appStoreReviewDetails/r-1",
            "POST /v1/appStoreReviewDetails"
        ])
        // 入れていない欄だけを送る
        #expect(try attributes(transport.requests[1]) == ["contactPhone": "+81 90 0000 0000"])
        #expect(try attributes(transport.requests[2]).count == 4)
    }

    @Test func listsEveryAppAcrossPages() async throws {
        let first = """
            {"data":[{"type":"apps","id":"6740000001","attributes":{"bundleId":"jp.example.A","name":"A"}}],
             "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=Mg&limit=200"}}
            """
        let second = #"{"data":[{"type":"apps","id":"6740000002","attributes":{"bundleId":"jp.example.B","name":"B"}}],"links":{}}"#
        let transport = StubTransport([.json(200, first), .json(200, second)])
        let apps = try await client(transport).allApps()
        #expect(apps.map(\.id) == ["6740000001", "6740000002"])
        #expect(query(transport.requests[1])["cursor"] == "Mg")
    }
}
