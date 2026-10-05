@testable import AskHubKit
import Foundation
import Testing

struct GitHubClientTests {
    private struct Issue: Decodable, Equatable {
        let number: Int
    }

    private let sleeper = SleepRecorder()
    private let fixedNow = Date(timeIntervalSince1970: 1_000)

    private func makeClient(_ http: MockHTTPClient, retryPolicy: RetryPolicy = .default) -> GitHubClient {
        let sleeper = sleeper
        let now = fixedNow
        return GitHubClient(
            token: "github_pat_secret",
            http: http,
            retryPolicy: retryPolicy,
            sleep: { sleeper.sleep($0) },
            now: { now }
        )
    }

    // MARK: - リクエスト

    @Test func sendsAuthorizationAndAPIHeaders() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{"number":1}"#)])
        let issue = try await makeClient(http).get("repos/o/r/issues/1", as: Issue.self)
        #expect(issue == Issue(number: 1))
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/issues/1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func ignoresLocalCache() async throws {
        // GitHub API の応答は max-age=60 なので、キャッシュを使うと閉じた直後の Issue を open と読む
        let http = MockHTTPClient([
            .init(status: 200, body: #"{"number":1}"#),
            .init(status: 200, body: #"{"number":2}"#)
        ])
        let client = makeClient(http)
        _ = try await client.get("repos/o/r/issues/1", as: Issue.self)
        _ = try await client.send("PATCH", "repos/o/r/issues/2", body: ["state": "closed"], as: Issue.self)
        #expect(http.requests.map(\.cachePolicy) == [.reloadIgnoringLocalCacheData, .reloadIgnoringLocalCacheData])
        #expect(URLSession.uncached.configuration.urlCache == nil)
        #expect(URLSession.uncached.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func httpErrorCarriesMessageWithoutToken() async {
        let http = MockHTTPClient([.init(status: 404, body: #"{"message":"Not Found"}"#)])
        await #expect(throws: GitHubError.http(status: 404, message: "Not Found")) {
            try await makeClient(http).get("repos/o/r", as: Issue.self)
        }
    }

    // MARK: - ページング

    @Test func followsLinkHeaderUntilLastPage() async throws {
        let http = MockHTTPClient([
            .init(
                status: 200,
                body: #"[{"number":1},{"number":2}]"#,
                headers: ["Link": #"<https://api.github.com/repos/o/r/issues?per_page=100&page=2>; rel="next", <https://api.github.com/repos/o/r/issues?per_page=100&page=2>; rel="last""#]
            ),
            .init(status: 200, body: #"[{"number":3}]"#)
        ])
        let issues = try await makeClient(http).getAllPages("repos/o/r/issues", of: Issue.self)
        #expect(issues.map(\.number) == [1, 2, 3])
        #expect(http.requests.count == 2)
        #expect(http.requests[0].url?.query()?.contains("per_page=100") == true)
        #expect(http.requests[1].url?.query()?.contains("page=2") == true)
    }

    @Test(arguments: [
        "https://evil.example.com/steal?page=2",
        // 同じホストでも、平文の通信や別のポートにはトークンを送らない
        "http://api.github.com/repos/o/r/issues?page=2",
        "https://api.github.com:8443/repos/o/r/issues?page=2"
    ])
    func refusesToFollowLinkToAnotherOrigin(_ next: String) async {
        let http = MockHTTPClient([
            .init(status: 200, body: "[]", headers: ["Link": "<\(next)>; rel=\"next\""])
        ])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeClient(http).getAllPages("repos/o/r/issues", of: Issue.self)
        }
        #expect(http.requests.count == 1)
    }

    @Test func treatsDefaultPortAndHostCaseAsSameOrigin() throws {
        let base = try #require(URL(string: "https://api.github.com/"))
        let next = try #require(URL(string: "https://API.GitHub.com:443/repos/o/r/issues?page=2"))
        #expect(GitHubClient.isSameOrigin(next, base))
    }

    // MARK: - レート制限

    @Test func retriesAfterRetryAfterHeader() async throws {
        let http = MockHTTPClient([
            .init(status: 429, body: "{}", headers: ["Retry-After": "5"]),
            .init(status: 200, body: #"{"number":1}"#)
        ])
        let issue = try await makeClient(http).get("repos/o/r/issues/1", as: Issue.self)
        #expect(issue == Issue(number: 1))
        #expect(sleeper.recorded == [.seconds(5)])
    }

    @Test func waitsUntilPrimaryRateLimitResets() async throws {
        let http = MockHTTPClient([
            .init(status: 403, body: "{}", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1030"]),
            .init(status: 200, body: #"{"number":1}"#)
        ])
        _ = try await makeClient(http).get("repos/o/r/issues/1", as: Issue.self)
        #expect(sleeper.recorded == [.seconds(31)])
    }

    @Test func throwsWhenWaitExceedsLimit() async {
        let http = MockHTTPClient([.init(status: 429, body: "{}", headers: ["Retry-After": "3600"])])
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(3600))) {
            try await makeClient(http).get("repos/o/r", as: Issue.self)
        }
        #expect(sleeper.recorded.isEmpty)
    }

    @Test func throwsAfterMaxRetries() async {
        let limited = MockHTTPClient.Response(status: 429, body: "{}", headers: ["Retry-After": "1"])
        let http = MockHTTPClient([limited, limited, limited])
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(1))) {
            try await makeClient(http, retryPolicy: RetryPolicy(maxRetries: 2, maxWait: .seconds(60))).get("repos/o/r", as: Issue.self)
        }
        #expect(http.requests.count == 3)
        #expect(sleeper.recorded.count == 2)
    }

    @Test func forbiddenWithoutRateLimitHeadersIsNotRetried() async {
        let http = MockHTTPClient([.init(status: 403, body: #"{"message":"Resource not accessible by personal access token"}"#)])
        await #expect(throws: GitHubError.http(status: 403, message: "Resource not accessible by personal access token")) {
            try await makeClient(http).get("repos/o/r", as: Issue.self)
        }
        #expect(sleeper.recorded.isEmpty)
    }

    // MARK: - 本文付きのリクエスト

    @Test func sendsJSONBody() async throws {
        struct Body: Encodable, Sendable {
            let body: String
        }
        let http = MockHTTPClient([.init(status: 201, body: #"{"number":7}"#)])
        let created = try await makeClient(http).send("POST", "repos/o/r/issues/1/comments", body: Body(body: "回答: A"), as: Issue.self)
        #expect(created == Issue(number: 7))
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(sent == ["body": "回答: A"])
    }
}
