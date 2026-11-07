@testable import AskHubPullRequests
import Foundation
import Testing

struct JobLogTests {
    private static let signed = "https://results-receiver.actions.githubusercontent.com/logs/1?sig=abc"

    @Test func followsRedirectWithoutToken() async throws {
        let transport = StubTransport([
            .init(status: 302, headers: ["Location": Self.signed]),
            .init(status: 200, body: Data("2026-11-07T09:00:00.0000000Z error: cannot find 'Ranking' in scope\n".utf8))
        ])
        let log = try await Fixture.client(transport).jobLog(jobID: 42)
        #expect(log.contains("cannot find 'Ranking' in scope"))
        let requests = transport.requests
        #expect(Fixture.path(requests.first) == "/repos/shilokuma-inc/ask-hub-apple/actions/jobs/42/logs")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.token)")
        // 署名つきの URL には、トークンを渡さない
        #expect(requests.last?.url?.absoluteString == Self.signed)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        // 末尾だけを頼む
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == "bytes=-\(GitHubPullRequests.maximumLogBytes)")
    }

    @Test func keepsTailOfLongLog() async throws {
        let long = String(repeating: "x", count: GitHubPullRequests.maximumLogBytes) + "\nerror: the last line"
        let transport = StubTransport([.init(status: 302, headers: ["Location": Self.signed]), .init(status: 200, body: Data(long.utf8))])
        let log = try await Fixture.client(transport).jobLog(jobID: 42)
        #expect(log.utf8.count == GitHubPullRequests.maximumLogBytes)
        #expect(log.hasSuffix("error: the last line"))
    }

    @Test func refusesRedirectToAPIHostOrPlainHTTP() async throws {
        // リポジトリの移管・改名のリダイレクトは追わない（トークンを付けない要求を API に送らない）
        let moved = StubTransport([.init(status: 301, headers: ["Location": "https://api.github.com/repositories/1/actions/jobs/42/logs"])])
        await #expect(throws: PullRequestError.redirected(status: 301)) { try await Fixture.client(moved).jobLog(jobID: 42) }
        #expect(moved.requests.count == 1)
        let plain = StubTransport([.init(status: 302, headers: ["Location": "http://example.com/log"])])
        await #expect(throws: PullRequestError.redirected(status: 302)) { try await Fixture.client(plain).jobLog(jobID: 42) }
        #expect(plain.requests.count == 1)
    }

    @Test func reportsExpiredLogs() async throws {
        let transport = StubTransport([.json(410, #"{"message":"Gone"}"#)])
        await #expect(throws: PullRequestError.unexpected(status: 410, message: "Gone")) {
            try await Fixture.client(transport).jobLog(jobID: 42)
        }
    }
}
