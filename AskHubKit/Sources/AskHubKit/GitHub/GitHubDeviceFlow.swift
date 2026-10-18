import Foundation

/// GitHub の OAuth のデバイスフローでユーザーのトークンを得るクライアント。
///
/// 1. `start()` でデバイスコードとユーザーコードを受け取る
/// 2. ユーザーコードを画面に出し、`verificationURI` をブラウザで開いてもらう
/// 3. `waitForToken(_:)` で、ユーザーが承認するまで `interval` ごとにトークンを問い合わせる
///
/// client secret は使わない（デバイスフローでは不要で、アプリに入れると誰でも取り出せる）。
/// 得たトークンとデバイスコードはエラー・ログ・URL に含めない（本文にだけ載せる）。
public struct GitHubDeviceFlow: Sendable {
    public static let defaultBaseURL = URL(string: "https://github.com")!

    /// ユーザーに承認してもらうための情報
    public struct Authorization: Sendable, Equatable {
        /// トークンの問い合わせに使うコード。画面に出さない
        let deviceCode: String
        /// ユーザーが `verificationURI` の画面に入力するコード（例: `WDJB-MJHT`）
        public let userCode: String
        /// ユーザーコードを入力する画面
        public let verificationURI: URL
        /// デバイスコードの有効期限
        public let expiresAt: Date
        /// 問い合わせの間隔（GitHub が指定した値）
        public let interval: Duration
    }

    /// サインインで得たトークン
    public struct Token: Sendable, Equatable {
        public let accessToken: String
        /// 付与されたスコープ（OAuth App のとき。GitHub App では空）
        public let scope: String
    }

    /// デバイスフローの失敗。トークンとデバイスコードの値は含めない
    public enum Failure: Error, Equatable, Sendable {
        /// ユーザーが承認する前にデバイスコードの期限が切れた
        case expired
        /// ユーザーが承認を取り消した
        case accessDenied
        /// アプリの設定でデバイスフローが有効になっていない
        case deviceFlowDisabled
        /// そのほかの GitHub のエラー（`error` の値）
        case oauth(code: String, description: String?)
        /// 2xx 以外のステータスで、`error` を含まない応答
        case http(status: Int)
        /// 応答を解釈できない
        case invalidResponse
    }

    /// `slow_down` のときに間隔を延ばす幅（RFC 8628 の 3.5）
    static let slowDownIncrement: Duration = .seconds(5)

    private let clientID: String
    private let scope: String?
    private let http: any HTTPClient
    private let baseURL: URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - clientID: GitHub App / OAuth App の client ID（秘密ではない）
    ///   - scope: OAuth App で求めるスコープ（空白区切り）。GitHub App では無視されるので `nil` でよい
    ///   - sleep: 問い合わせの間に待つ処理。テストでは実際に待たない実装に差し替える
    ///   - now: 現在時刻。デバイスコードの期限の判定に使う
    public init(
        clientID: String,
        scope: String? = nil,
        http: any HTTPClient = URLSession.uncached,
        baseURL: URL = defaultBaseURL,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clientID = clientID
        self.scope = scope
        self.http = http
        self.baseURL = baseURL
        self.sleep = sleep
        self.now = now
    }

    /// デバイスコードとユーザーコードを発行してもらう
    public func start() async throws -> Authorization {
        var fields = ["client_id": clientID]
        if let scope, !scope.isEmpty {
            fields["scope"] = scope
        }
        let data = try await post("login/device/code", fields: fields)
        guard let response = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data),
              let verificationURI = URL(string: response.verificationURI),
              verificationURI.scheme?.lowercased() == "https" else {
            throw Self.failure(from: data) ?? Failure.invalidResponse
        }
        return Authorization(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURI: verificationURI,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn)),
            interval: .seconds(max(response.interval ?? 5, 1))
        )
    }

    /// ユーザーが承認するまで問い合わせ、トークンを返す。
    ///
    /// `authorization_pending` は待って続け、`slow_down` は間隔を延ばして続ける。
    /// 期限切れ・拒否・そのほかのエラーで終わる。呼び出し元の `Task` を取り消すと `CancellationError` で終わる
    public func waitForToken(_ authorization: Authorization) async throws -> Token {
        var interval = authorization.interval
        while true {
            try await sleep(interval)
            guard now() < authorization.expiresAt else {
                throw Failure.expired
            }
            let data = try await post("login/oauth/access_token", fields: [
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            if let token = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data) {
                return Token(accessToken: token.accessToken, scope: token.scope ?? "")
            }
            guard let error = try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data) else {
                throw Failure.invalidResponse
            }
            switch error.error {
            case "authorization_pending":
                continue

            case "slow_down":
                // 新しい間隔が返ればそれに従い、無ければ 5 秒延ばす
                interval = error.interval.map { .seconds($0) } ?? interval + Self.slowDownIncrement

            default:
                throw Self.failure(for: error)
            }
        }
    }

    // MARK: - Private

    private func post(_ path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.failure(from: data) ?? Failure.http(status: response.statusCode)
        }
        return data
    }

    /// `application/x-www-form-urlencoded` の本文。キーの順に並べる
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private static func failure(from data: Data) -> Failure? {
        (try? JSONDecoder().decode(DeviceFlowErrorResponse.self, from: data)).map(failure(for:))
    }

    private static func failure(for error: DeviceFlowErrorResponse) -> Failure {
        switch error.error {
        case "expired_token":
            .expired

        case "access_denied":
            .accessDenied

        case "device_flow_disabled":
            .deviceFlowDisabled

        default:
            .oauth(code: error.error, description: error.errorDescription)
        }
    }
}

// MARK: - 応答の形

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenResponse: Decodable {
    let accessToken: String
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case scope
    }
}

private struct DeviceFlowErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case interval
    }
}
