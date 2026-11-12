import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// APNs に送るための設定。秘密を含まない（鍵そのものは Keychain の `apnsKey` に置く）
public struct APNsConfiguration: Codable, Equatable, Sendable {
    /// Apple Developer で作った APNs の鍵の id（英大文字・数字の 10 文字）
    public var keyId: String
    /// 鍵を作ったチームの Team ID（英大文字・数字の 10 文字）
    public var teamId: String
    /// 通知を受けるアプリの Bundle ID（iOS と macOS で同じ）
    public var topic: String

    public static let defaultTopic = "jp.shilokuma.AskHub"

    public init(keyId: String, teamId: String, topic: String = defaultTopic) {
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
    }

    /// 設定の形の問題。空なら使える
    public var problems: [String] {
        var problems: [String] = []
        if !Self.isAppleID(keyId) { problems.append("APNs の鍵の id は英大文字・数字の 10 文字") }
        if !Self.isAppleID(teamId) { problems.append("Team ID は英大文字・数字の 10 文字") }
        let isBundleID = (3...155).contains(topic.utf8.count) && topic.contains(".") && !topic.hasPrefix(".") && !topic.hasSuffix(".")
            && topic.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            }
        if !isBundleID { problems.append("topic は Bundle ID の形") }
        return problems
    }

    private static func isAppleID(_ text: String) -> Bool {
        text.utf8.count == 10 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }
}

/// APNs の鍵（Apple Developer で作った .p8。PKCS#8 の PEM）
public enum APNsKey {
    /// .p8 の中身を読む。読めなければ nil
    public static func parse(_ data: Data) -> P256.Signing.PrivateKey? {
        guard data.count <= 4_096, let text = String(bytes: data, encoding: .utf8) else { return nil }
        return try? P256.Signing.PrivateKey(pemRepresentation: text)
    }

    /// Keychain の鍵の様子（値は出さない）
    public static func state(in secrets: any SecretStore) -> SelfCheck.State {
        let data: Data?
        do {
            data = try secrets.read(.apnsKey)
        } catch {
            return .invalid
        }
        guard let data else { return .missing }
        return parse(data) == nil ? .invalid : .ok
    }
}

/// APNs の認証に使う JWT（ES256。`kid` は鍵の id、`iss` は Team ID）
enum APNsToken {
    /// 作ってから 1 時間で断られ、20 分より短い間隔で作り直しても断られるので、40 分使い回す
    static let lifetime: TimeInterval = 40 * 60

    static func make(keyID: String, teamID: String, key: P256.Signing.PrivateKey, issuedAt: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "ES256", "kid": keyID])
        let claims = try encoder.encode(Claims(iss: teamID, iat: Int(issuedAt.timeIntervalSince1970)))
        let input = Base64URL.encode(header) + "." + Base64URL.encode(claims)
        // JWS の ES256 の署名は、DER ではなく r と s をつないだ 64 バイト
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return input + "." + Base64URL.encode(signature)
    }

    private struct Claims: Encodable {
        var iss: String
        var iat: Int
    }
}

/// APNs の HTTP/2 の API（`/3/device/<token>`）に送る。鍵は JWT を作るときに Keychain から読む
public actor APNsSender: PushSender {
    nonisolated let configuration: APNsConfiguration
    nonisolated let secrets: any SecretStore
    nonisolated let transport: any HTTPTransport
    nonisolated let now: @Sendable () -> Date
    nonisolated let log: @Sendable (String) -> Void
    private var token: (value: String, issuedAt: Date)?

    public init(
        configuration: APNsConfiguration,
        secrets: any SecretStore,
        transport: any HTTPTransport = APNsURLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.secrets = secrets
        self.transport = transport
        self.now = now
        self.log = log
    }

    /// 端末が受け取らなくても、1 日は APNs に送り直してもらう
    static let expiration: TimeInterval = 24 * 60 * 60

    public func send(_ notice: PushNotice, to device: DeviceFile) async -> PushDelivery {
        guard device.push.service == .apns, let environment = device.push.environment else { return .rejected("APNs の宛先でない") }
        let body: Data
        do {
            body = try Self.payload(notice)
        } catch {
            return .failed("通知の中身を作れない（\(error)）")
        }
        switch await post(notice, body: body, token: device.push.token, environment: environment) {
        case let .done(result):
            return result

        case .badDeviceToken:
            break
        }
        // トークンと宛先の環境が食い違うと BadDeviceToken で断られる（環境を取り違えて登録した古い版のアプリなど）。
        // もう一方の環境のトークンのことがあるので、1 回だけそちらに送る
        let other: APNsEnvironment = environment == .production ? .development : .production
        switch await post(notice, body: body, token: device.push.token, environment: other) {
        case .done(.delivered):
            log("端末 \(device.device) の宛先は \(environment.rawValue) と書いてあるが、\(other.rawValue) で届いた（アプリを新しい版にして開くと登録し直す）")
            return .delivered

        case let .done(result):
            return result

        case .badDeviceToken:
            return .rejected("400 BadDeviceToken（\(environment.rawValue)・\(other.rawValue) のどちらでも）")
        }
    }

    /// 1 つの環境に送った結果
    private enum Attempt {
        case done(PushDelivery)
        /// トークンがこの環境のものでない
        case badDeviceToken
    }

    /// 1 つの環境に送る。古くなった JWT で断られたら、作り直して 1 回だけ送り直す
    private func post(_ notice: PushNotice, body: Data, token: String, environment: APNsEnvironment) async -> Attempt {
        for renewing in [false, true] {
            let jwt: String
            switch bearer(renewing: renewing) {
            case let .success(value): jwt = value
            case let .failure(problem): return .done(.failed(problem.message))
            }
            let request = request(notice, body: body, url: Self.url(token: token, environment: environment), jwt: jwt)
            let response: (Data, HTTPURLResponse)
            do {
                response = try await transport.send(request)
            } catch {
                return .done(.failed("APNs につながらない（\(error.localizedDescription)）"))
            }
            let (data, http) = response
            let reason = (try? JSONDecoder().decode(Reply.self, from: data))?.reason ?? ""
            switch (http.statusCode, reason) {
            case (200, _):
                return .done(.delivered)
            case (403, "ExpiredProviderToken") where !renewing:
                continue
            case (400, "BadDeviceToken"):
                return .badDeviceToken
            case (400, "DeviceTokenNotForTopic"), (410, _):
                return .done(.rejected("\(http.statusCode) \(reason)"))
            default:
                return .done(.failed("APNs が断った（\(http.statusCode) \(reason)）"))
            }
        }
        return .done(.failed("APNs が JWT を受け付けない"))
    }

    private struct Problem: Error {
        var message: String
    }

    /// 使い回せる JWT。無いか古いか、`renewing` なら作り直す
    private func bearer(renewing: Bool) -> Result<String, Problem> {
        let now = now()
        if !renewing, let token, now.timeIntervalSince(token.issuedAt) >= 0, now.timeIntervalSince(token.issuedAt) < APNsToken.lifetime {
            return .success(token.value)
        }
        let data: Data?
        do {
            data = try secrets.read(.apnsKey)
        } catch {
            return .failure(Problem(message: "Keychain を読めない（\(error)）"))
        }
        guard let data else { return .failure(Problem(message: "Keychain に APNs の鍵が無い（askhub-commander apns で登録する）")) }
        guard let key = APNsKey.parse(data) else { return .failure(Problem(message: "Keychain の APNs の鍵の形が違う")) }
        do {
            let value = try APNsToken.make(keyID: configuration.keyId, teamID: configuration.teamId, key: key, issuedAt: now)
            token = (value, now)
            return .success(value)
        } catch {
            return .failure(Problem(message: "JWT を作れない（\(error)）"))
        }
    }

    /// 端末の宛先の URL
    static func url(token: String, environment: APNsEnvironment) -> URL {
        let host = switch environment {
        case .production: "api.push.apple.com"
        case .development: "api.sandbox.push.apple.com"
        }
        // token は DeviceFile が 16 進だけに限っているので、パスにそのまま入れてよい
        return URL(string: "https://\(host)/3/device/\(token)")!
    }

    nonisolated func request(_ notice: PushNotice, body: Data, url: URL, jwt: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(now().timeIntervalSince1970 + Self.expiration)), forHTTPHeaderField: "apns-expiration")
        request.setValue(notice.collapseID, forHTTPHeaderField: "apns-collapse-id")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    /// 通知の中身。`askhub` はクライアントが開く先
    static func payload(_ notice: PushNotice) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let alert = APNsAlert.Alert(title: notice.title, subtitle: notice.subtitle, body: notice.body)
        return try encoder.encode(APNsPayload(aps: .init(alert: alert, sound: "default", threadID: notice.thread), askhub: notice.target))
    }

    private struct Reply: Decodable {
        var reason: String?
    }
}

/// APNs に送る通知の中身（`aps` は APNs が読む欄、`askhub` はクライアントが開く先）
private struct APNsPayload: Encodable {
    var aps: APNsAlert
    var askhub: [String: String]
}

private struct APNsAlert: Encodable {
    struct Alert: Encodable {
        var title: String
        var subtitle: String?
        var body: String
    }

    enum CodingKeys: String, CodingKey {
        case alert, sound
        case threadID = "thread-id"
    }

    var alert: Alert
    var sound: String
    var threadID: String
}

/// APNs に送る `URLSession`（HTTP/2 は `URLSession` が TLS の ALPN で選ぶ）。Cookie・資格情報・キャッシュを持たない
public struct APNsURLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}
