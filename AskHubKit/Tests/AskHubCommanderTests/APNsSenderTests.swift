@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// 決まった順に APNs の応答を返し、受けた要求を残す（ネットワークに出ない）
final class APNsStubTransport: HTTPTransport {
    enum Reply: Sendable {
        case status(Int, reason: String? = nil)
        case unreachable
    }

    private let state: OSAllocatedUnfairLock<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) {
        state = OSAllocatedUnfairLock(initialState: (replies, []))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state -> Reply in
            state.requests.append(request)
            return state.replies.isEmpty ? .unreachable : state.replies.removeFirst()
        }
        let headers = ["apns-id": UUID().uuidString]
        guard case let .status(status, reason) = reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)
        else { throw URLError(.notConnectedToInternet) }
        return (reason.map { Data(#"{"reason":"\#($0)"}"#.utf8) } ?? Data(), response)
    }
}

/// APNs に送る部品（JWT・要求の形・応答の扱い）
struct APNsSenderTests {
    static let now = EpicHandlersTests.now
    static let configuration = APNsConfiguration(keyId: "ABC123DEFG", teamId: "XU74X3434S")

    let key = P256.Signing.PrivateKey()
    let clock = TestClock(APNsSenderTests.now)

    var notice: PushNotice {
        PushNotice(
            title: "ランキング",
            subtitle: "shilokuma-inc/askhub-sandbox",
            body: "質問 2 件が回答を待っています",
            thread: "01JCEP1C000000000000000001",
            target: ["repo": "shilokuma-inc/askhub-sandbox", "epic": "01JCEP1C000000000000000001"],
            keys: ["question/a", "question/b"]
        )
    }

    func device(_ environment: APNsEnvironment = .production) -> DeviceFile {
        let id = IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation)
        let push = DeviceFile.Push(service: .apns, token: NotifierTests.token, environment: environment)
        return DeviceFile(device: id, platform: .ios, push: push, updatedAt: Timestamp(Self.now))
    }

    func sender(
        _ transport: APNsStubTransport,
        secrets: (any SecretStore)? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> APNsSender {
        let clock = clock
        let secrets = secrets ?? InMemorySecretStore([.apnsKey: Data(key.pemRepresentation.utf8)])
        return APNsSender(configuration: Self.configuration, secrets: secrets, transport: transport, now: { clock.now }, log: log)
    }

    /// JWT のヘッダーと中身
    struct JWT {
        var header: [String: String]
        var issuer: String
        var issuedAt: Int
    }

    /// 要求の JWT を読む（署名は鍵で確かめる）
    func decode(_ request: URLRequest) throws -> JWT {
        let authorization = try #require(request.value(forHTTPHeaderField: "authorization"))
        try #require(authorization.hasPrefix("bearer "))
        let parts = authorization.dropFirst(7).split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: #require(Base64URL.decode(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        let header = try JSONDecoder().decode([String: String].self, from: #require(Base64URL.decode(parts[0])))
        let claimsData = try #require(Base64URL.decode(parts[1]))
        let claims = try #require(try JSONSerialization.jsonObject(with: claimsData) as? [String: Any])
        return JWT(header: header, issuer: try #require(claims["iss"] as? String), issuedAt: try #require(claims["iat"] as? Int))
    }

    @Test func sendsAlertSignedWithKeychainKey() async throws {
        let transport = APNsStubTransport([.status(200)])
        #expect(await sender(transport).send(notice, to: device()) == .delivered)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.push.apple.com/3/device/\(NotifierTests.token)")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "jp.shilokuma.AskHub")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(request.value(forHTTPHeaderField: "apns-priority") == "10")
        #expect(request.value(forHTTPHeaderField: "apns-expiration") == String(Int(Self.now.timeIntervalSince1970) + 86_400))
        #expect(request.value(forHTTPHeaderField: "apns-collapse-id") == notice.collapseID)
        #expect(notice.collapseID.utf8.count == 64)
        let jwt = try decode(request)
        #expect(jwt.header == ["alg": "ES256", "kid": "ABC123DEFG"])
        #expect(jwt.issuer == "XU74X3434S")
        #expect(jwt.issuedAt == Int(Self.now.timeIntervalSince1970))

        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])
        let alert = ["title": "ランキング", "subtitle": "shilokuma-inc/askhub-sandbox", "body": "質問 2 件が回答を待っています"]
        #expect(aps["alert"] as? [String: String] == alert)
        #expect(aps["thread-id"] as? String == notice.thread)
        #expect(aps["sound"] as? String == "default")
        #expect(body["askhub"] as? [String: String] == notice.target)
    }

    @Test func sendsDevelopmentBuildsToSandbox() async throws {
        let transport = APNsStubTransport([.status(200)])
        #expect(await sender(transport).send(notice, to: device(.development)) == .delivered)
        #expect(transport.requests.first?.url?.host == "api.sandbox.push.apple.com")
    }

    @Test func reusesTokenForFortyMinutes() async throws {
        let transport = APNsStubTransport([.status(200), .status(200), .status(200)])
        let sender = sender(transport)
        _ = await sender.send(notice, to: device())
        clock.advance(minutes: 39)
        _ = await sender.send(notice, to: device())
        clock.advance(minutes: 2)
        _ = await sender.send(notice, to: device())

        let tokens = transport.requests.map { $0.value(forHTTPHeaderField: "authorization") }
        #expect(tokens[0] == tokens[1])
        #expect(tokens[1] != tokens[2])
        #expect(try decode(transport.requests[2]).issuedAt == Int(Self.now.timeIntervalSince1970) + 41 * 60)
    }

    @Test func renewsExpiredTokenOnlyOnce() async throws {
        let renewed = APNsStubTransport([.status(403, reason: "ExpiredProviderToken"), .status(200)])
        #expect(await sender(renewed).send(notice, to: device()) == .delivered)
        #expect(renewed.requests.count == 2)

        let stillExpired = APNsStubTransport([.status(403, reason: "ExpiredProviderToken"), .status(403, reason: "ExpiredProviderToken")])
        #expect(await sender(stillExpired).send(notice, to: device()) == .failed("APNs が断った（403 ExpiredProviderToken）"))
        #expect(stillExpired.requests.count == 2)
    }

    @Test(arguments: [
        (APNsStubTransport.Reply.status(410, reason: "Unregistered"), PushDelivery.rejected("410 Unregistered")),
        (.status(400, reason: "DeviceTokenNotForTopic"), .rejected("400 DeviceTokenNotForTopic")),
        (.status(400, reason: "BadTopic"), .failed("APNs が断った（400 BadTopic）")),
        (.status(403, reason: "InvalidProviderToken"), .failed("APNs が断った（403 InvalidProviderToken）")),
        (.status(429, reason: "TooManyRequests"), .failed("APNs が断った（429 TooManyRequests）")),
        (.status(503, reason: "ServiceUnavailable"), .failed("APNs が断った（503 ServiceUnavailable）"))
    ])
    func classifiesReplies(_ reply: APNsStubTransport.Reply, _ expected: PushDelivery) async {
        #expect(await sender(APNsStubTransport([reply])).send(notice, to: device()) == expected)
    }

    /// 開発用の署名の Release の版は、development のトークンを production と書いていた。BadDeviceToken なら、もう一方の環境に 1 回だけ送る
    @Test(arguments: [APNsEnvironment.production, .development])
    func retriesOtherEnvironmentOnBadDeviceToken(_ written: APNsEnvironment) async throws {
        let transport = APNsStubTransport([.status(400, reason: "BadDeviceToken"), .status(200)])
        let logs = OSAllocatedUnfairLock(initialState: [String]())
        let sender = sender(transport) { line in logs.withLock { $0.append(line) } }
        #expect(await sender.send(notice, to: device(written)) == .delivered)

        let hosts = ["api.push.apple.com", "api.sandbox.push.apple.com"]
        #expect(transport.requests.map { $0.url?.host } == (written == .production ? hosts : hosts.reversed()))
        #expect(transport.requests.map { $0.url?.path } == Array(repeating: "/3/device/\(NotifierTests.token)", count: 2))
        #expect(logs.withLock { $0 }.count == 1)
        #expect(logs.withLock { $0 }.first?.contains("\(written.rawValue) と書いてあるが") == true)
    }

    /// もう一方の環境でも使えなければ、その結果を返す（どちらでも BadDeviceToken なら、送り直さない）
    @Test(arguments: [
        (
            APNsStubTransport.Reply.status(400, reason: "BadDeviceToken"),
            PushDelivery.rejected("400 BadDeviceToken（production・development のどちらでも）")
        ),
        (.status(410, reason: "Unregistered"), .rejected("410 Unregistered")),
        (.status(503, reason: "ServiceUnavailable"), .failed("APNs が断った（503 ServiceUnavailable）"))
    ])
    func reportsOtherEnvironmentResult(_ reply: APNsStubTransport.Reply, _ expected: PushDelivery) async {
        let transport = APNsStubTransport([.status(400, reason: "BadDeviceToken"), reply])
        #expect(await sender(transport).send(notice, to: device()) == expected)
        #expect(transport.requests.count == 2)
    }

    @Test func failsWithoutKeyOrConnection() async throws {
        let unreachable = APNsStubTransport([.unreachable])
        let result = await sender(unreachable).send(notice, to: device())
        #expect(result != .delivered && "\(result)".contains("APNs につながらない"))

        // 鍵が無い・形が違うときは送らない
        let transport = APNsStubTransport([.status(200)])
        let missing = await sender(transport, secrets: InMemorySecretStore()).send(notice, to: device())
        #expect(missing == .failed("Keychain に APNs の鍵が無い（askhub-commander apns で登録する）"))
        let broken = InMemorySecretStore([.apnsKey: Data("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".utf8)])
        #expect(await sender(transport, secrets: broken).send(notice, to: device()) == .failed("Keychain の APNs の鍵の形が違う"))
        #expect(transport.requests.isEmpty)
        #expect(APNsKey.state(in: broken) == .invalid)
        #expect(APNsKey.state(in: InMemorySecretStore()) == .missing)
        #expect(APNsKey.state(in: InMemorySecretStore([.apnsKey: Data(key.pemRepresentation.utf8)])) == .ok)
    }

    @Test func refusesDeviceWithoutEnvironment() async {
        var file = device()
        file.push.environment = nil
        let transport = APNsStubTransport([.status(200)])
        #expect(await sender(transport).send(notice, to: file) == .rejected("APNs の宛先でない"))
        #expect(transport.requests.isEmpty)
    }
}
