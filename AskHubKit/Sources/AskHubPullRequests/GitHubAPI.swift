import AskHubProtocol
import AskHubStateStore
import Foundation

/// 1 つのリポジトリの GitHub の API を呼ぶ土台（要求の組み立て・送信・ページング・GraphQL）。
///
/// - トークンは要求のたびに、リポジトリの持ち主を渡して閉包から読み、`Authorization` にだけ入れる。URL・エラーの文には出さない
/// - 次のページの URL は `Link` ヘッダーから読む。API と違うホストの URL には送らない（トークンを渡さないため）
struct GitHubAPI: Sendable {
    let repository: RepositoryFullName
    let apiBase: URL
    let transport: any HTTPTransport
    let now: @Sendable () -> Date
    /// リポジトリの持ち主を受け取り、その持ち主のトークンを返す
    let token: @Sendable (_ owner: String) async throws -> String

    /// 1 つの一覧で追うページの上限（100 件ずつで 1 万件）。超えたら形が違うとみなす
    static let maxPages = 100

    // MARK: - REST

    /// `repos/<owner>/<repo>/` からのパスの URL
    func url(_ path: String, query: [URLQueryItem] = []) throws(PullRequestError) -> URL {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("repos/\(repository.owner)/\(repository.name)/\(path)"),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw .invalidArgument("URL を作れない") }
        return url
    }

    /// 要求を送り、2xx なら本文を返す。それ以外は失敗の種類に分ける
    func send(
        _ method: String,
        _ url: URL,
        body: (any Encodable & Sendable)? = nil
    ) async throws(PullRequestError) -> (Data, HTTPURLResponse) {
        let request = try await makeRequest(method, url, body: body)
        let (data, response) = try await transmit(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PullRequestError.classify(response, body: data, now: now())
        }
        return (data, response)
    }

    /// GET して、決まった型で読む
    func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: Value.Type) async throws(PullRequestError) -> Value {
        let (data, _) = try await send("GET", url(path, query: query))
        return try Self.decode(type, from: data, what: path)
    }

    /// GET して本文を返す。ログのように、短い間だけ使える署名つきの URL へリダイレクトする API に使う。
    ///
    /// 行き先にはトークンを付けずに取りに行く（署名で認められるため）。API と同じホストへのリダイレクト（リポジトリの移管・改名）と、
    /// https 以外の行き先は追わない。`tailBytes` を渡すと、行き先には末尾のその大きさだけを頼む（`Range`。応じない行き先は全体を返す）
    func download(_ path: String, tailBytes: Int? = nil) async throws(PullRequestError) -> Data {
        let request = try await makeRequest("GET", url(path), body: nil)
        let (data, response) = try await transmit(request)
        if (200..<300).contains(response.statusCode) { return data }
        guard (300..<400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
              target.scheme == "https", target.host != apiBase.host else {
            throw PullRequestError.classify(response, body: data, now: now())
        }
        var signed = URLRequest(url: target)
        if let tailBytes { signed.setValue("bytes=-\(tailBytes)", forHTTPHeaderField: "Range") }
        let (body, final) = try await transmit(signed)
        guard (200..<300).contains(final.statusCode) else { throw PullRequestError.classify(final, body: body, now: now()) }
        return body
    }

    /// 一覧を `Link` ヘッダーの `rel="next"` が無くなるまで読み、ページを順に返す
    func pages<Page: Decodable>(_ path: String, query: [URLQueryItem], as type: Page.Type) async throws(PullRequestError) -> [Page] {
        var next: URL? = try url(path, query: query)
        var pages: [Page] = []
        while let current = next {
            guard pages.count < Self.maxPages else { throw .malformed("\(path) のページが \(Self.maxPages) を超えた") }
            let (data, response) = try await send("GET", current)
            pages.append(try Self.decode(type, from: data, what: path))
            next = try nextPage(response)
        }
        return pages
    }

    /// `Link` ヘッダーの次のページ。API と違うホスト・スキームの URL は断る
    private func nextPage(_ response: HTTPURLResponse) throws(PullRequestError) -> URL? {
        guard let next = LinkHeader.next(response.value(forHTTPHeaderField: "Link")) else { return nil }
        guard next.scheme == apiBase.scheme, next.host == apiBase.host, next.port == apiBase.port else {
            throw .malformed("次のページの URL が API のホストと違う")
        }
        return next
    }

    // MARK: - GraphQL

    /// GraphQL の問い合わせを送り、`data` を読む。
    ///
    /// GraphQL は上限や見つからないことも 200 の `errors` で返すので、`errors` を見て失敗の種類に分ける
    func graphQL<Variables: Encodable & Sendable, Response: Decodable>(
        _ query: String,
        variables: Variables,
        as type: Response.Type
    ) async throws(PullRequestError) -> Response {
        let body = GraphQLRequest(query: query, variables: variables)
        let (data, response) = try await send("POST", apiBase.appendingPathComponent("graphql"), body: body)
        let decoded = try Self.decode(GraphQLResponse<Response>.self, from: data, what: "graphql")
        if let errors = decoded.errors, !errors.isEmpty {
            throw GraphQLError.classify(errors, response: response, now: now())
        }
        guard let value = decoded.data else { throw .malformed("GraphQL の応答に data が無い") }
        return value
    }

    // MARK: - 共通

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, what: String) throws(PullRequestError) -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // REST は snake_case。GraphQL の camelCase は `_` を含まないので変わらない
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw .malformed("\(what) の応答を読めない")
        }
    }

    private func makeRequest(_ method: String, _ url: URL, body: (any Encodable & Sendable)?) async throws(PullRequestError) -> URLRequest {
        let token: String
        do {
            token = try await self.token(repository.owner)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .tokenUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw .invalidArgument("要求の本文を作れない")
            }
        }
        return request
    }

    private func transmit(_ request: URLRequest) async throws(PullRequestError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch let error as URLError {
            throw .transport("URLError \(error.code.rawValue)")
        } catch {
            throw .transport(String(describing: type(of: error)))
        }
    }
}

/// `Link` ヘッダー（`<https://api.github.com/…?page=2>; rel="next", <…?page=5>; rel="last"`）
enum LinkHeader {
    static func next(_ header: String?) -> URL? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  parts.dropFirst().contains(#"rel="next""#) else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}

private struct GraphQLRequest<Variables: Encodable & Sendable>: Encodable, Sendable {
    let query: String
    let variables: Variables
}

private struct GraphQLResponse<Value: Decodable>: Decodable {
    let data: Value?
    let errors: [GraphQLError]?
}

/// GraphQL の `errors` の 1 件
struct GraphQLError: Decodable {
    let type: String?
    let message: String?

    /// 一次の上限は 200 で返り、`x-ratelimit-remaining` が 0 になる（`type` が `RATE_LIMITED` のこともある）。
    /// 二次の上限は 200 か 403 で返る（403 は REST と同じく `PullRequestError.classify` で分ける）
    static func classify(_ errors: [Self], response: HTTPURLResponse, now: Date) -> PullRequestError {
        let message = errors.compactMap(\.message).joined(separator: " / ")
        let types = Set(errors.compactMap(\.type))
        let limited = types.contains("RATE_LIMITED") || message.localizedCaseInsensitiveContains("rate limit")
        if limited || PullRequestError.resetWait(response, now: now) != nil {
            let wait = PullRequestError.resetWait(response, now: now) ?? PullRequestError.defaultSecondaryWait
            return .rateLimited(retryAfter: wait)
        }
        if types.contains("NOT_FOUND") { return .notFound }
        if types.contains("FORBIDDEN") { return .forbidden(message: message) }
        return .unexpected(status: response.statusCode, message: message.isEmpty ? nil : message)
    }
}
