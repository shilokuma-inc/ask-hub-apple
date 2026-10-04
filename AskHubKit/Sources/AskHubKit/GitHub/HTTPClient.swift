import Foundation

/// HTTP リクエストの送信先。テストではモックに差し替える
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }
        return (data, response)
    }
}

extension URLSession {
    /// キャッシュを持たないセッション。GitHub API の応答は `cache-control: max-age=60` なので、
    /// 既定の URLCache では最大 60 秒古い状態を読む（CLI のディスクキャッシュは別プロセスとも共有される）。
    /// 応答（private リポジトリの内容を含む）をディスクに残さないためにも使う
    public static let uncached: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
