import Foundation

/// HTTP の要求を送る部品。テストでは決まった応答を返すものに差し替える
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// GitHub の API に送る `URLSession`。
///
/// - リダイレクトを追わない。リポジトリの移管・改名のリダイレクトを `URLSession` が送り直すと、`Authorization` が付かずに
///   書き込みが 401・読み取りが未認証の上限になるため（`LEARNINGS.md`）。3xx はそのまま呼び出し側に返す
/// - `URLSession` の HTTP のキャッシュを使わない。ETag はこちらで持ち、304 を自分で受け取る（304 は上限に数えられないため）
/// - Cookie と資格情報を保存しない
public struct GitHubURLSessionTransport: HTTPTransport {
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
        let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// リダイレクトを追わず、3xx の応答をそのまま返させる
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
