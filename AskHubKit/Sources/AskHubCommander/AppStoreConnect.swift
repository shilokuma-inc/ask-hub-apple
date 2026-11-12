import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// App Store Connect の API キーの設定。秘密を含まない（鍵そのものは Keychain の `appStoreConnectKey(id:)` に置く）。
/// Apple のチームごとに 1 つ（`docs/renewal/release.md` の「配信の検知と後作業」）
public struct AppStoreConnectConfiguration: Codable, Equatable, Sendable {
    /// App Store Connect で作った API キーの id（英大文字・数字の 10 文字）
    public var keyId: String
    /// キーの Issuer ID（UUID）
    public var issuerId: String

    public init(keyId: String, issuerId: String) {
        self.keyId = keyId
        self.issuerId = issuerId
    }

    /// 設定の形の問題。空なら使える
    public var problems: [String] {
        var problems: [String] = []
        let isKeyID = keyId.utf8.count == 10 && keyId.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
        if !isKeyID { problems.append("App Store Connect の API キーの id は英大文字・数字の 10 文字") }
        // `UUID(uuidString:)` は大文字・小文字のどちらも受け付ける。JWT の `iss` には書いたまま入れる
        if UUID(uuidString: issuerId) == nil { problems.append("Issuer ID は UUID の形（xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）") }
        return problems
    }
}

/// App Store Connect の API キー（App Store Connect から落とした .p8。PKCS#8 の PEM。APNs の鍵と同じ形）
public enum AppStoreConnectKey {
    /// .p8 の中身を読む。読めなければ nil
    public static func parse(_ data: Data) -> P256.Signing.PrivateKey? {
        APNsKey.parse(data)
    }

    /// Keychain の鍵の様子（値は出さない）
    public static func state(of configuration: AppStoreConnectConfiguration, in secrets: any SecretStore) -> SelfCheck.State {
        let data: Data?
        do {
            data = try secrets.read(.appStoreConnectKey(id: configuration.keyId))
        } catch {
            return .invalid
        }
        guard let data else { return .missing }
        return parse(data) == nil ? .invalid : .ok
    }
}

/// App Store Connect の API の認証に使う JWT（ES256。`kid` は鍵の id、`iss` は Issuer ID、`aud` は `appstoreconnect-v1`）
enum AppStoreConnectToken {
    /// 有効期間（`exp - iat`）。App Store Connect は 20 分より長いものを断る
    static let lifetime: TimeInterval = 15 * 60
    /// 作り直すまで使い回す長さ（期限の前に余裕を残す）
    static let reuse: TimeInterval = 10 * 60
    static let audience = "appstoreconnect-v1"

    static func make(keyID: String, issuerID: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let issued = Int(issuedAt.timeIntervalSince1970)
        let claims = try encoder.encode(Claims(iss: issuerID, iat: issued, exp: issued + Int(lifetime), aud: audience))
        let input = Base64URL.encode(header) + "." + Base64URL.encode(claims)
        // JWS の ES256 の署名は、DER ではなく r と s をつないだ 64 バイト
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return input + "." + Base64URL.encode(signature)
    }

    private struct Claims: Encodable {
        var iss: String
        var iat: Int
        var exp: Int
        var aud: String
    }
}

/// App Store Connect のアプリ
public struct AppStoreApp: Equatable, Sendable {
    /// App Store Connect のアプリの id（数字だけ）
    public var id: String
    public var bundleId: String
    public var name: String

    public init(id: String, bundleId: String, name: String) {
        self.id = id
        self.bundleId = bundleId
        self.name = name
    }
}

/// 配信中（`READY_FOR_DISTRIBUTION`）の版
public struct LiveAppVersion: Equatable, Sendable {
    public var platform: AppStorePlatform
    public var version: MarketingVersion
    /// 配信したビルドの番号（`CFBundleVersion`）。ビルドが読めなければ nil
    public var build: String?
    /// そのビルドを上げた時刻。読めなければ nil
    public var uploadedAt: Date?

    public init(platform: AppStorePlatform, version: MarketingVersion, build: String?, uploadedAt: Date?) {
        self.platform = platform
        self.version = version
        self.build = build
        self.uploadedAt = uploadedAt
    }
}

/// App Store Connect の API の失敗。鍵の値・JWT は含めない
public enum AppStoreConnectError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Keychain に鍵が無い・読めない
    case keyUnavailable(String)
    /// 401・403（鍵が取り消された・役割が足りない）
    case unauthorized(status: Int)
    /// 429（鍵ごとの 1 時間の上限）。次に読むときにやり直す
    case rateLimited
    /// 5xx・つながらない
    case unavailable(String)
    /// 応答の形が違う・ほかの 4xx
    case malformed(String)

    public var description: String {
        switch self {
        case let .keyUnavailable(detail): "App Store Connect の鍵を使えない（\(detail)）"
        case let .unauthorized(status): "App Store Connect に断られた（\(status)。鍵が取り消されたか、役割が足りない）"
        case .rateLimited: "App Store Connect の上限に当たった（429）"
        case let .unavailable(detail): "App Store Connect に届かない（\(detail)）"
        case let .malformed(detail): "App Store Connect の応答を読めない（\(detail)）"
        }
    }
}

/// App Store Connect の読み取り（テストでは差し替える）
public protocol AppStoreConnectReading: Sendable {
    /// 鍵の id（どのチームの鍵か）
    var keyID: String { get }
    /// Bundle ID のどれかと完全に一致するアプリ
    func apps(bundleIDs: [String]) async throws(AppStoreConnectError) -> [AppStoreApp]
    /// アプリの配信中の版（プラットフォームごとに 1 つ）
    func liveVersions(of appID: String) async throws(AppStoreConnectError) -> [LiveAppVersion]
}

/// 1 つの API キーで App Store Connect を読む。鍵は JWT を作るときに Keychain から読み、JWT は使い回す
public actor AppStoreConnectClient: AppStoreConnectReading {
    nonisolated let configuration: AppStoreConnectConfiguration
    nonisolated let secrets: any SecretStore
    nonisolated let transport: any HTTPTransport
    nonisolated let apiBase: URL
    nonisolated let now: @Sendable () -> Date
    private var token: (value: String, issuedAt: Date)?

    /// 1 回の要求で読む件数の上限（App Store Connect の上限）
    static let pageLimit = 200

    public init(
        configuration: AppStoreConnectConfiguration,
        secrets: any SecretStore,
        transport: any HTTPTransport,
        apiBase: URL = URL(string: "https://api.appstoreconnect.apple.com")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.secrets = secrets
        self.transport = transport
        self.apiBase = apiBase
        self.now = now
    }

    nonisolated public var keyID: String { configuration.keyId }

    public func apps(bundleIDs: [String]) async throws(AppStoreConnectError) -> [AppStoreApp] {
        let wanted = bundleIDs.filter(Self.isBundleID)
        guard !wanted.isEmpty else { return [] }
        let query = [
            URLQueryItem(name: "filter[bundleId]", value: wanted.joined(separator: ",")),
            URLQueryItem(name: "fields[apps]", value: "bundleId,name"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        let response = try await get("v1/apps", query: query, as: AppStoreConnectAppsResponse.self)
        // 絞り込みが完全一致とは文書に書かれていないので、返った Bundle ID を比べ直す
        return response.data.compactMap { app in
            guard let bundleID = app.attributes?.bundleId, wanted.contains(bundleID), Self.isAppID(app.id) else { return nil }
            return AppStoreApp(id: app.id, bundleId: bundleID, name: app.attributes?.name ?? bundleID)
        }
    }

    public func liveVersions(of appID: String) async throws(AppStoreConnectError) -> [LiveAppVersion] {
        guard Self.isAppID(appID) else { throw .malformed("アプリの id の形が違う") }
        let query = [
            URLQueryItem(name: "filter[appVersionState]", value: "READY_FOR_DISTRIBUTION"),
            URLQueryItem(name: "include", value: "build"),
            URLQueryItem(name: "fields[appStoreVersions]", value: "platform,versionString,appVersionState,build"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        let response = try await get("v1/apps/\(appID)/appStoreVersions", query: query, as: AppStoreConnectVersionsResponse.self)
        return Self.liveVersions(response)
    }

    /// 応答から配信中の版を読む。形の読めない版（知らないプラットフォーム・版の番号の形が違う）は飛ばす
    static func liveVersions(_ response: AppStoreConnectVersionsResponse) -> [LiveAppVersion] {
        let builds = Dictionary(
            (response.included ?? []).filter { $0.type == "builds" }.map { ($0.id, $0.attributes) },
            uniquingKeysWith: { first, _ in first }
        )
        var versions: [LiveAppVersion] = []
        for item in response.data {
            guard let attributes = item.attributes, attributes.appVersionState == "READY_FOR_DISTRIBUTION",
                  let platform = attributes.platform.flatMap(AppStorePlatform.init(appStoreConnectValue:)),
                  let version = attributes.versionString.flatMap(MarketingVersion.init(rawValue:)),
                  !versions.contains(where: { $0.platform == platform }) else { continue }
            let build = item.relationships?.build?.data.flatMap { builds[$0.id, default: nil] }
            let number = build?.version.flatMap { ReleaseFile.isBuildNumber($0) ? $0 : nil }
            versions.append(LiveAppVersion(
                platform: platform,
                version: version,
                build: number,
                uploadedAt: build?.uploadedDate.flatMap(Self.date)
            ))
        }
        return versions
    }

    // MARK: - 要求

    private func get<Value: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        as type: Value.Type
    ) async throws(AppStoreConnectError) -> Value {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw .malformed("URL を作れない") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .unavailable(String(describing: Swift.type(of: error)))
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // 鍵を入れ替えたかもしれないので、次は作り直す
            token = nil
            throw .unauthorized(status: response.statusCode)
        case 429:
            throw .rateLimited
        case 500...:
            throw .unavailable("HTTP \(response.statusCode)")
        default:
            throw .malformed("HTTP \(response.statusCode)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .malformed("\(path) の応答")
        }
    }

    private func currentToken() throws(AppStoreConnectError) -> String {
        let now = now()
        if let token, now.timeIntervalSince(token.issuedAt) < AppStoreConnectToken.reuse, now >= token.issuedAt {
            return token.value
        }
        let data: Data?
        do {
            data = try secrets.read(.appStoreConnectKey(id: configuration.keyId))
        } catch {
            throw .keyUnavailable("Keychain を読めない")
        }
        guard let data else { throw .keyUnavailable("Keychain に \(configuration.keyId) の鍵が無い") }
        guard let key = AppStoreConnectKey.parse(data) else { throw .keyUnavailable("Keychain の \(configuration.keyId) の鍵を読めない") }
        do {
            let value = try AppStoreConnectToken.make(keyID: configuration.keyId, issuerID: configuration.issuerId, key: key, issuedAt: now)
            token = (value, now)
            return value
        } catch {
            throw .keyUnavailable("JWT を作れない")
        }
    }

    // MARK: - 形

    /// Bundle ID（英数字・`.`・`-`）。クエリに入れるので、ほかの文字を含むものは使わない
    static func isBundleID(_ text: String) -> Bool {
        (3...155).contains(text.utf8.count) && text.contains(".") && !text.hasPrefix(".") && !text.hasSuffix(".")
            && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            }
    }

    /// アプリの id（数字だけ）。パスに入れるので、ほかの文字を含むものは使わない
    static func isAppID(_ text: String) -> Bool {
        (1...20).contains(text.utf8.count) && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// App Store Connect の時刻（`2026-10-18T06:05:33-07:00`・`2026-10-18T13:05:33.000+00:00` など。時差と小数の秒がつくことがある）
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

struct AppStoreConnectResource<Attributes: Decodable>: Decodable {
    var type: String
    var id: String
    var attributes: Attributes?
}

struct AppStoreConnectAppsResponse: Decodable {
    struct Attributes: Decodable {
        var bundleId: String?
        var name: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}

struct AppStoreConnectVersionsResponse: Decodable {
    struct Attributes: Decodable {
        var platform: String?
        var versionString: String?
        var appVersionState: String?
    }

    struct Relationships: Decodable {
        var build: BuildRelationship?
    }

    struct BuildRelationship: Decodable {
        var data: BuildLink?
    }

    struct BuildLink: Decodable {
        var id: String
    }

    struct Item: Decodable {
        var type: String
        var id: String
        var attributes: Attributes?
        var relationships: Relationships?
    }

    struct BuildAttributes: Decodable {
        var version: String?
        var uploadedDate: String?
    }

    var data: [Item]
    var included: [AppStoreConnectResource<BuildAttributes>]?
}
