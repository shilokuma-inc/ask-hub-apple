import Foundation

/// GitHub の REST / GraphQL API のクライアント。
///
/// - 一覧の取得は `Link` ヘッダーの `rel="next"` を最後まで追う
/// - レート制限（403 / 429）は `RetryPolicy` に従って待ってから再試行する
/// - トークンは `Authorization` ヘッダーにだけ載せ、エラーやログには含めない
public struct GitHubClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.github.com")!

    private let token: String
    private let http: any HTTPClient
    private let baseURL: URL
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - sleep: レート制限で待つ処理。テストでは実際に待たない実装に差し替える
    ///   - now: 現在時刻。`x-ratelimit-reset` までの待ち時間の計算に使う
    public init(
        token: String,
        http: any HTTPClient = URLSession.uncached,
        baseURL: URL = defaultBaseURL,
        retryPolicy: RetryPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.token = token
        self.http = http
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.now = now
    }

    // MARK: - REST

    /// REST API を GET してデコードする
    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await perform(makeRequest(url: url(for: path, query: query), method: "GET"))
        return try Self.decode(type, from: data)
    }

    /// 一覧を返す REST API を、`Link` ヘッダーの次のページが無くなるまで取得して連結する。
    /// `per_page` を指定しなければ 100（最大値）にする
    public func getAllPages<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        of type: T.Type = T.self
    ) async throws -> [T] {
        var query = query
        if !query.contains(where: { $0.name == "per_page" }) {
            query.append(URLQueryItem(name: "per_page", value: "100"))
        }
        var items: [T] = []
        var next: URL? = url(for: path, query: query)
        while let current = next {
            let (data, response) = try await perform(makeRequest(url: current, method: "GET"))
            items += try Self.decode([T].self, from: data)
            next = LinkHeader.nextURL(from: response.value(forHTTPHeaderField: "Link"))
            // トークンを別の宛先や平文の通信で送らないよう、次のページは baseURL と同じオリジンに限る
            if let next, !Self.isSameOrigin(next, baseURL) {
                throw GitHubError.invalidResponse
            }
        }
        return items
    }

    /// スキーム・ホスト・ポートが一致するか。ポートの省略はスキームの既定値として比べる
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(of url: URL) -> Int? {
            url.port ?? ["https": 443, "http": 80][url.scheme?.lowercased() ?? ""]
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host()?.lowercased() == rhs.host()?.lowercased()
            && port(of: lhs) == port(of: rhs)
    }

    /// REST API に本文付きのリクエスト（POST / PATCH / PUT / DELETE）を送り、レスポンスをデコードする
    public func send<Body: Encodable & Sendable, T: Decodable>(
        _ method: String,
        _ path: String,
        body: Body,
        as type: T.Type = T.self
    ) async throws -> T {
        var request = makeRequest(url: url(for: path, query: []), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(request)
        return try Self.decode(type, from: data)
    }

    /// 本文の無いリクエスト（ラベルの削除など）を送る。レスポンスの本文は読まない
    public func send(_ method: String, _ path: String) async throws {
        _ = try await perform(makeRequest(url: url(for: path, query: []), method: method))
    }

    // MARK: - GraphQL

    /// GraphQL のクエリを実行し、`data` をデコードして返す。`errors` があればエラーにする
    public func graphQL<T: Decodable>(
        _ query: String,
        variables: [String: GraphQLVariable] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        var request = makeRequest(url: baseURL.appending(path: "graphql"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, _) = try await perform(request)
        let response = try Self.decode(GraphQLResponse<T>.self, from: data)
        if let errors = response.errors, !errors.isEmpty {
            throw GitHubError.graphQL(messages: errors.map(\.message))
        }
        guard let result = response.data else {
            throw GitHubError.invalidResponse
        }
        return result
    }

    // MARK: - 共通

    private func url(for path: String, query: [URLQueryItem]) -> URL {
        let url = baseURL.appending(path: path)
        return query.isEmpty ? url : url.appending(queryItems: query)
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 渡されたセッションにキャッシュがあっても、古い応答を使わない
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AskHub", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// リクエストを送り、2xx ならそのまま返す。レート制限なら待って再試行し、それ以外はエラーにする
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var retries = 0
        while true {
            let (data, response) = try await http.send(request)
            if (200..<300).contains(response.statusCode) {
                return (data, response)
            }
            if let wait = RateLimit.waitDuration(for: response, now: now()) {
                guard retries < retryPolicy.maxRetries, wait <= retryPolicy.maxWait else {
                    throw GitHubError.rateLimited(retryAfter: wait)
                }
                retries += 1
                try await sleep(wait)
                continue
            }
            let message = try? JSONDecoder().decode(ErrorBody.self, from: data).message
            throw GitHubError.http(status: response.statusCode, message: message)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// GitHub がエラー時に返す本文
private struct ErrorBody: Decodable {
    let message: String
}
