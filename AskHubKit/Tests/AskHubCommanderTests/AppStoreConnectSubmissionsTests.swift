@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

/// App Store Connect の審査の API（版の状態・ビルド・What's New・審査に出す・取り下げ・手動の配信）の要求と応答
struct AppStoreConnectSubmissionsTests {
    private func client(_ transport: StubTransport) -> AppStoreConnectClient {
        AppStoreConnectTests().client(transport)
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url else { return [:] }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["data"] as? [String: Any])
    }

    @Test func readsVersionsInEveryStateButReplaced() async throws {
        let body = """
            {"data":[
              {"type":"appStoreVersions","id":"v1",
               "attributes":{"platform":"IOS","versionString":"1.3.0",
                             "appVersionState":"READY_FOR_DISTRIBUTION","releaseType":"AFTER_APPROVAL"},
               "relationships":{"build":{"data":{"type":"builds","id":"b30"}}}},
              {"type":"appStoreVersions","id":"v2",
               "attributes":{"platform":"IOS","versionString":"1.4.0","appVersionState":"IN_REVIEW","releaseType":"MANUAL"},
               "relationships":{"build":{"data":{"type":"builds","id":"b45"}}}},
              {"type":"appStoreVersions","id":"v3",
               "attributes":{"platform":"IOS","versionString":"1.5.0","appVersionState":"SOMETHING_NEW"}},
              {"type":"appStoreVersions","id":"v/4",
               "attributes":{"platform":"IOS","versionString":"1.6.0","appVersionState":"IN_REVIEW"}}
            ],
            "included":[
              {"type":"builds","id":"b30","attributes":{"version":"30","uploadedDate":"2026-11-01T00:00:00Z"}},
              {"type":"builds","id":"b45","attributes":{"version":"45","uploadedDate":"2026-11-20T01:40:00Z"}}
            ]}
            """
        let transport = StubTransport([.json(200, body)])
        let versions = try await client(transport).versions(of: "6740000001")
        #expect(versions.map(\.id) == ["v1", "v2"])
        #expect(versions[1] == AppStoreVersionInfo(
            id: "v2",
            platform: .iOS,
            versionString: "1.4.0",
            state: .inReview,
            releaseType: .manual,
            build: "45",
            uploadedAt: Date(timeIntervalSince1970: 1_795_138_800)
        ))
        let items = query(transport.requests.first)
        #expect(transport.requests.first?.url?.path == "/v1/apps/6740000001/appStoreVersions")
        let states = items["filter[appVersionState]"]?.split(separator: ",").map(String.init) ?? []
        #expect(states.contains("IN_REVIEW") && states.contains("READY_FOR_DISTRIBUTION") && states.contains("PENDING_DEVELOPER_RELEASE"))
        #expect(!states.contains("REPLACED_WITH_NEW_VERSION"))
    }

    @Test func readsValidBuildsOfTheVersion() async throws {
        let body = """
            {"data":[
              {"type":"builds","id":"b46",
               "attributes":{"version":"46","uploadedDate":"2026-11-20T03:00:00Z","expired":false,"usesNonExemptEncryption":false},
               "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-mac"}}}},
              {"type":"builds","id":"b45","attributes":{"version":"45","uploadedDate":"2026-11-20T01:40:00Z","expired":false},
               "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-ios"}}}},
              {"type":"builds","id":"b9","attributes":{"version":"9","uploadedDate":"2026-11-20T01:00:00Z"},
               "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"p-old"}}}}
            ],
            "included":[
              {"type":"preReleaseVersions","id":"p-mac","attributes":{"platform":"MAC_OS","version":"1.4.0"}},
              {"type":"preReleaseVersions","id":"p-ios","attributes":{"platform":"IOS","version":"1.4.0"}},
              {"type":"preReleaseVersions","id":"p-old","attributes":{"platform":"IOS","version":"1.3.0"}}
            ]}
            """
        let transport = StubTransport([.json(200, body)])
        let builds = try await client(transport).builds(of: "6740000001", version: MarketingVersion(rawValue: "1.4.0")!)
        #expect(builds.map(\.id) == ["b46", "b45"])
        #expect(builds[0].platform == .macOS && builds[0].usesNonExemptEncryption == false)
        // 輸出コンプライアンスに答えていないビルドは nil のまま持つ（司令塔は代わりに答えない）
        #expect(builds[1].platform == .iOS && builds[1].usesNonExemptEncryption == nil)
        let items = query(transport.requests.first)
        #expect(transport.requests.first?.url?.path == "/v1/builds")
        #expect(items["filter[app]"] == "6740000001")
        #expect(items["filter[preReleaseVersion.version]"] == "1.4.0")
        #expect(items["filter[processingState]"] == "VALID")
        #expect(items["sort"] == "-uploadedDate")
    }

    @Test func readsLocalizationsAndWritesWhatsNew() async throws {
        let list = """
            {"data":[
              {"type":"appStoreVersionLocalizations","id":"l-ja","attributes":{"locale":"ja","whatsNew":null}},
              {"type":"appStoreVersionLocalizations","id":"l-en","attributes":{"locale":"en-US","whatsNew":"Old"}},
              {"type":"appStoreVersionLocalizations","id":"l-x","attributes":{"locale":"bad locale"}}
            ]}
            """
        let transport = StubTransport([.json(200, list), .json(200, #"{"data":{"type":"appStoreVersionLocalizations","id":"l-ja"}}"#)])
        let client = client(transport)
        let localizations = try await client.localizations(of: "v2")
        #expect(localizations == [
            AppStoreLocalization(id: "l-ja", locale: "ja", whatsNew: nil),
            AppStoreLocalization(id: "l-en", locale: "en-US", whatsNew: "Old")
        ])
        try await client.updateWhatsNew("l-ja", text: "・速くなりました")
        let patch = transport.requests[1]
        #expect(patch.httpMethod == "PATCH")
        #expect(patch.url?.path == "/v1/appStoreVersionLocalizations/l-ja")
        #expect(patch.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try body(patch)
        #expect(data["type"] as? String == "appStoreVersionLocalizations")
        #expect(data["id"] as? String == "l-ja")
        #expect((data["attributes"] as? [String: Any])?["whatsNew"] as? String == "・速くなりました")
    }

    @Test func readsAndWritesListing() async throws {
        let list = """
            {"data":[
              {"type":"appStoreVersionLocalizations","id":"l-ja","attributes":{"locale":"ja","whatsNew":null,
               "description":"推しの予定を数えるアプリ","keywords":"推し活,カウントダウン","promotionalText":""}}
            ]}
            """
        let transport = StubTransport([.json(200, list), .json(200, #"{"data":{"type":"appStoreVersionLocalizations","id":"l-ja"}}"#)])
        let client = client(transport)
        let localizations = try await client.localizations(of: "v2")
        // 空の欄は無いものとして持つ
        #expect(localizations.first?.listing == ListingText(locale: "ja", description: "推しの予定を数えるアプリ", keywords: "推し活,カウントダウン"))
        let fields = query(transport.requests.first)["fields[appStoreVersionLocalizations]"]?.split(separator: ",").map(String.init) ?? []
        #expect(Set(fields) == ["locale", "whatsNew", "description", "keywords", "promotionalText"])
        // 送るのは nil でない欄だけ（空の文字列は送る）
        try await client.updateListing("l-ja", ListingText(locale: "ja", keywords: "推し活,ウィジェット", promotionalText: ""))
        let attributes = try #require(try body(transport.requests[1])["attributes"] as? [String: Any])
        #expect(Set(attributes.keys) == ["keywords", "promotionalText"])
        #expect(attributes["keywords"] as? String == "推し活,ウィジェット")
        #expect((attributes["promotionalText"] as? String)?.isEmpty == true)
        // 変える欄が無ければ送らない
        try await client.updateListing("l-ja", ListingText(locale: "ja"))
        #expect(transport.requests.count == 2)
    }

    @Test func createsAndUpdatesVersions() async throws {
        let transport = StubTransport([
            .json(201, #"{"data":{"type":"appStoreVersions","id":"v-new","attributes":{"appVersionState":"PREPARE_FOR_SUBMISSION"}}}"#),
            .json(200, #"{"data":{"type":"appStoreVersions","id":"v-new"}}"#)
        ])
        let client = client(transport)
        let version = MarketingVersion(rawValue: "1.4.0")!
        let created = try await client.createVersion(
            of: "6740000001", platform: .iOS, AppStoreVersionChange(version: version, releaseType: .afterApproval, buildID: "b45")
        )
        #expect(created.id == "v-new" && created.state == .prepareForSubmission)
        let post = try body(transport.requests[0])
        #expect(transport.requests[0].httpMethod == "POST")
        #expect(transport.requests[0].url?.path == "/v1/appStoreVersions")
        let attributes = try #require(post["attributes"] as? [String: Any])
        #expect(attributes["platform"] as? String == "IOS")
        #expect(attributes["versionString"] as? String == "1.4.0")
        #expect(attributes["releaseType"] as? String == "AFTER_APPROVAL")
        // 作るときは日時を送らない（直すときだけ null で消す）
        #expect(attributes["earliestReleaseDate"] == nil)
        let relationships = try #require(post["relationships"] as? [String: Any])
        #expect(((relationships["build"] as? [String: Any])?["data"] as? [String: String]) == ["type": "builds", "id": "b45"])
        #expect(((relationships["app"] as? [String: Any])?["data"] as? [String: String]) == ["type": "apps", "id": "6740000001"])

        let date = Date(timeIntervalSince1970: 1_795_651_200)
        try await client.updateVersion(
            "v-new", AppStoreVersionChange(version: version, releaseType: .scheduled, earliestReleaseDate: date, buildID: "b46")
        )
        let patch = try body(transport.requests[1])
        #expect(transport.requests[1].httpMethod == "PATCH")
        #expect(transport.requests[1].url?.path == "/v1/appStoreVersions/v-new")
        #expect((patch["attributes"] as? [String: Any])?["earliestReleaseDate"] as? String == "2026-11-26T00:00:00Z")
        #expect((patch["attributes"] as? [String: Any])?["releaseType"] as? String == "SCHEDULED")
    }

    @Test func choosesBuildWithoutTouchingReleaseTypeAndDeletesVersions() async throws {
        let transport = StubTransport([
            .json(201, #"{"data":{"type":"appStoreVersions","id":"v-slot"}}"#),
            .json(200, #"{"data":{"type":"appStoreVersions","id":"v-slot"}}"#),
            .json(204, ""),
            .json(409, #"{"errors":[{"detail":"The version can't be deleted."}]}"#)
        ])
        let client = client(transport)
        let version = MarketingVersion(rawValue: "1.4.0")!
        // 枠を作るときはビルドを選ばない
        let slot = AppStoreVersionChange(version: version, releaseType: .afterApproval, buildID: nil)
        _ = try await client.createVersion(of: "6740000001", platform: .iOS, slot)
        let created = try body(transport.requests[0])
        #expect((created["relationships"] as? [String: Any])?["build"] == nil)
        // ビルドだけ選ぶときは、配信の方式と日時を送らない（人が App Store Connect で選んだものを残す）
        try await client.updateVersion("v-slot", AppStoreVersionChange(version: version, releaseType: nil, buildID: "b45"))
        let patch = try body(transport.requests[1])
        #expect((patch["attributes"] as? [String: String]) == ["versionString": "1.4.0"])
        let build = (patch["relationships"] as? [String: Any])?["build"] as? [String: Any]
        #expect(build?["data"] as? [String: String] == ["type": "builds", "id": "b45"])
        try await client.deleteVersion("v-slot")
        #expect(transport.requests[2].httpMethod == "DELETE")
        #expect(transport.requests[2].url?.path == "/v1/appStoreVersions/v-slot")
        await #expect(throws: AppStoreConnectError.refused(status: 409, detail: "The version can't be deleted.")) {
            try await client.deleteVersion("v-slot")
        }
    }

    @Test func submitsCancelsAndReleases() async throws {
        let open = """
            {"data":[{"type":"reviewSubmissions","id":"s1","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"},
              "relationships":{"appStoreVersionForReview":{"data":{"type":"appStoreVersions","id":"v2"}}}},
              {"type":"reviewSubmissions","id":"s0","attributes":{"platform":"IOS","state":"CANCELING"}}]}
            """
        let transport = StubTransport([
            .json(200, open),
            .json(201, #"{"data":{"type":"reviewSubmissions","id":"s2"}}"#),
            .json(201, #"{"data":{"type":"reviewSubmissionItems","id":"i1"}}"#),
            .json(200, #"{"data":{"type":"reviewSubmissions","id":"s2"}}"#),
            .json(200, #"{"data":{"type":"reviewSubmissions","id":"s2"}}"#),
            .json(201, #"{"data":{"type":"appStoreVersionReleaseRequests","id":"r1"}}"#)
        ])
        let client = client(transport)
        let submissions = try await client.reviewSubmissions(of: "6740000001", platform: .iOS)
        #expect(submissions == [AppStoreReviewSubmission(id: "s1", platform: .iOS, state: .readyForReview, versionID: "v2")])
        #expect(query(transport.requests[0])["filter[state]"] == "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES")
        #expect(query(transport.requests[0])["filter[platform]"] == "IOS")

        let created = try await client.createReviewSubmission(of: "6740000001", platform: .iOS)
        #expect(created.id == "s2")
        #expect((try body(transport.requests[1])["attributes"] as? [String: String]) == ["platform": "IOS"])
        try await client.addToReviewSubmission("s2", versionID: "v2")
        #expect(transport.requests[2].url?.path == "/v1/reviewSubmissionItems")
        try await client.submitReviewSubmission("s2")
        #expect(transport.requests[3].url?.path == "/v1/reviewSubmissions/s2")
        #expect((try body(transport.requests[3])["attributes"] as? [String: Bool]) == ["submitted": true])
        try await client.cancelReviewSubmission("s2")
        #expect((try body(transport.requests[4])["attributes"] as? [String: Bool]) == ["canceled": true])
        try await client.requestRelease(of: "v2")
        #expect(transport.requests[5].url?.path == "/v1/appStoreVersionReleaseRequests")
        let release = try body(transport.requests[5])
        let relationship = (release["relationships"] as? [String: Any])?["appStoreVersion"] as? [String: Any]
        #expect(relationship?["data"] as? [String: String] == ["type": "appStoreVersions", "id": "v2"])
    }

    @Test func reportsWhyAWriteWasRefused() async throws {
        let errors = #"{"errors":[{"status":"409","code":"STATE_ERROR","title":"t","detail":"You must provide a value for whatsNew."}]}"#
        await #expect(throws: AppStoreConnectError.refused(status: 409, detail: "You must provide a value for whatsNew.")) {
            try await client(StubTransport([.json(409, errors)])).submitReviewSubmission("s1")
        }
        await #expect(throws: AppStoreConnectError.refused(status: 422, detail: "理由は返されなかった")) {
            try await client(StubTransport([.json(422, "{}")])).requestRelease(of: "v1")
        }
        // 読み取りの 4xx は、こちらの要求の誤り
        await #expect(throws: AppStoreConnectError.malformed("HTTP 400")) {
            try await client(StubTransport([.json(400, errors)])).versions(of: "1")
        }
        // id の形が違えば送らない
        let transport = StubTransport([])
        await #expect(throws: AppStoreConnectError.self) { try await client(transport).cancelReviewSubmission("s/1") }
        await #expect(throws: AppStoreConnectError.self) { try await client(transport).updateWhatsNew("l 1", text: "x") }
        #expect(transport.requests.isEmpty)
    }

    @Test func tellsEditableVersions() {
        let editable: [AppStoreVersionState] = [.prepareForSubmission, .developerRejected, .rejected, .metadataRejected]
        for state in AppStoreVersionState.allCases {
            let version = AppStoreVersionInfo(id: "v", platform: .iOS, versionString: "1.4.0", state: state)
            #expect(version.isEditable == (editable.contains(state) || [.readyForReview, .invalidBinary].contains(state)), "\(state)")
        }
    }
}
