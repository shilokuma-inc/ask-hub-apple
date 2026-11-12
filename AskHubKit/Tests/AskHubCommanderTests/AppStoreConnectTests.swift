@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import CryptoKit
import Foundation
import Testing

/// App Store Connect の API キーの設定・JWT・配信中の版の読み取り
struct AppStoreConnectTests {
    static let configuration = AppStoreConnectConfiguration(keyId: "ABCDE12345", issuerId: "57246542-96fe-1a63-e053-0824d011072a")
    static let key = P256.Signing.PrivateKey()
    static let now = Date(timeIntervalSince1970: 1_794_490_551)

    func client(_ transport: StubTransport, secrets: InMemorySecretStore? = nil) -> AppStoreConnectClient {
        let secrets = secrets ?? InMemorySecretStore([.appStoreConnectKey(id: "ABCDE12345"): Data(Self.key.pemRepresentation.utf8)])
        return AppStoreConnectClient(configuration: Self.configuration, secrets: secrets, transport: transport, now: { Self.now })
    }

    @Test func checksConfigurationShape() {
        #expect(Self.configuration.problems.isEmpty)
        #expect(AppStoreConnectConfiguration(keyId: "abcde12345", issuerId: "x").problems.count == 2)
        #expect(AppStoreConnectConfiguration(keyId: "ABCDE1234", issuerId: Self.configuration.issuerId).problems.count == 1)
    }

    @Test func makesES256TokenForAppStoreConnect() throws {
        let token = try AppStoreConnectToken.make(
            keyID: "ABCDE12345",
            issuerID: Self.configuration.issuerId,
            key: Self.key,
            issuedAt: Self.now
        )
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let headerData = try #require(Base64URL.decode(parts[0]))
        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: String]
        #expect(header == ["alg": "ES256", "kid": "ABCDE12345", "typ": "JWT"])
        let claimsData = try #require(Base64URL.decode(parts[1]))
        let claims = try #require(try JSONSerialization.jsonObject(with: claimsData) as? [String: Any])
        #expect(claims["iss"] as? String == Self.configuration.issuerId)
        #expect(claims["aud"] as? String == "appstoreconnect-v1")
        let issued = try #require(claims["iat"] as? Int)
        let expires = try #require(claims["exp"] as? Int)
        // App Store Connect は 20 分より長いものを断る
        #expect(expires - issued == 15 * 60)
        let signatureData = try #require(Base64URL.decode(parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        #expect(Self.key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func findsAppsWithExactBundleID() async throws {
        let body = #"{"data":[{"type":"apps","id":"6740000001","attributes":{"bundleId":"jp.shilokuma.OshiCon","name":"推し活カウントダウン"}},"#
            + #"{"type":"apps","id":"6740000002","attributes":{"bundleId":"jp.shilokuma.OshiConLite","name":"x"}}]}"#
        let transport = StubTransport([.json(200, body)])
        let apps = try await client(transport).apps(bundleIDs: ["jp.shilokuma.OshiCon", "bad id"])
        #expect(apps == [AppStoreApp(id: "6740000001", bundleId: "jp.shilokuma.OshiCon", name: "推し活カウントダウン")])
        let url = try #require(transport.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // 形の違う Bundle ID はクエリに入れない
        #expect(items.first { $0.name == "filter[bundleId]" }?.value == "jp.shilokuma.OshiCon")
        #expect(url.path == "/v1/apps")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func readsLiveVersionsWithTheirBuilds() async throws {
        let body = """
            {"data":[
              {"type":"appStoreVersions","id":"v1",
               "attributes":{"platform":"IOS","versionString":"1.0.0","appVersionState":"READY_FOR_DISTRIBUTION"},
               "relationships":{"build":{"data":{"type":"builds","id":"b12"}}}},
              {"type":"appStoreVersions","id":"v2",
               "attributes":{"platform":"MAC_OS","versionString":"1.0","appVersionState":"READY_FOR_DISTRIBUTION"},
               "relationships":{"build":{"data":null}}},
              {"type":"appStoreVersions","id":"v3",
               "attributes":{"platform":"IOS","versionString":"1.1.0","appVersionState":"IN_REVIEW"}},
              {"type":"appStoreVersions","id":"v4",
               "attributes":{"platform":"WATCH_OS","versionString":"1.0.0","appVersionState":"READY_FOR_DISTRIBUTION"}}
            ],
            "included":[{"type":"builds","id":"b12","attributes":{"version":"12","uploadedDate":"2026-10-18T06:05:33-07:00"}}]}
            """
        let transport = StubTransport([.json(200, body)])
        let versions = try await client(transport).liveVersions(of: "6740000001")
        #expect(versions == [
            LiveAppVersion(
                platform: .iOS,
                version: MarketingVersion(rawValue: "1.0.0")!,
                build: "12",
                uploadedAt: Date(timeIntervalSince1970: 1_792_328_733)
            ),
            LiveAppVersion(platform: .macOS, version: MarketingVersion(rawValue: "1.0")!, build: nil, uploadedAt: nil)
        ])
        let url = try #require(transport.requests.first?.url)
        #expect(url.path == "/v1/apps/6740000001/appStoreVersions")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "filter[appVersionState]" }?.value == "READY_FOR_DISTRIBUTION")
        #expect(items.first { $0.name == "include" }?.value == "build")
    }

    @Test func reusesTokenUntilItIsOld() async throws {
        let empty = #"{"data":[]}"#
        let transport = StubTransport([.json(200, empty), .json(200, empty)])
        let client = client(transport)
        _ = try await client.apps(bundleIDs: ["jp.shilokuma.OshiCon"])
        _ = try await client.apps(bundleIDs: ["jp.shilokuma.OshiCon"])
        let tokens = transport.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens.count == 2 && tokens[0] == tokens[1])
    }

    @Test func classifiesFailures() async throws {
        await #expect(throws: AppStoreConnectError.unauthorized(status: 401)) {
            try await client(StubTransport([.json(401, "{}")])).liveVersions(of: "1")
        }
        await #expect(throws: AppStoreConnectError.rateLimited) {
            try await client(StubTransport([.json(429, "{}")])).liveVersions(of: "1")
        }
        await #expect(throws: AppStoreConnectError.unavailable("HTTP 503")) {
            try await client(StubTransport([.json(503, "{}")])).liveVersions(of: "1")
        }
        // id の形が違えば送らない
        let transport = StubTransport([])
        await #expect(throws: AppStoreConnectError.self) { try await client(transport).liveVersions(of: "../1") }
        #expect(transport.requests.isEmpty)
        // 鍵が無ければ送らない
        let keyless = StubTransport([])
        await #expect(throws: AppStoreConnectError.self) {
            try await client(keyless, secrets: InMemorySecretStore()).liveVersions(of: "1")
        }
        #expect(keyless.requests.isEmpty)
    }

    @Test func reportsKeyState() {
        #expect(AppStoreConnectKey.state(of: Self.configuration, in: InMemorySecretStore()) == .missing)
        let broken = InMemorySecretStore([.appStoreConnectKey(id: "ABCDE12345"): Data("x".utf8)])
        #expect(AppStoreConnectKey.state(of: Self.configuration, in: broken) == .invalid)
        let stored = InMemorySecretStore([.appStoreConnectKey(id: "ABCDE12345"): Data(Self.key.pemRepresentation.utf8)])
        #expect(AppStoreConnectKey.state(of: Self.configuration, in: stored) == .ok)
    }

    @Test func parsesSetupArgumentsAndReplacesSameKey() throws {
        let setup = try AppStoreConnectSetup.parse([
            "--key-id", "ABCDE12345", "--issuer-id", Self.configuration.issuerId, "--key-file", "~/AuthKey.p8"
        ])
        #expect(setup.configuration == Self.configuration)
        #expect(setup.keyFile == "~/AuthKey.p8")
        #expect(throws: MachineSetup.Failure.self) {
            try AppStoreConnectSetup.parse(["--key-id", "x", "--issuer-id", "y", "--key-file", "z"])
        }
        let other = AppStoreConnectConfiguration(keyId: "ZYXWV98765", issuerId: Self.configuration.issuerId)
        let renewed = AppStoreConnectConfiguration(keyId: "ABCDE12345", issuerId: "11111111-2222-3333-4444-555555555555")
        #expect(AppStoreConnectSetup.adding(renewed, to: [Self.configuration, other]) == [other, renewed])
        #expect(AppStoreConnectSetup.adding(Self.configuration, to: nil) == [Self.configuration])
    }
}
