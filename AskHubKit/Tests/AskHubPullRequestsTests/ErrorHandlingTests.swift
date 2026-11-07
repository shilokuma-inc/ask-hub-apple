@testable import AskHubPullRequests
import Foundation
import Testing

struct ErrorHandlingTests {
    private func readError(_ reply: StubTransport.Reply) async -> PullRequestError? {
        let transport = StubTransport([reply])
        do {
            _ = try await Fixture.client(transport).pullRequest(number: 7)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 上限

    @Test func primaryRateLimitWaitsUntilReset() async {
        let reset = Int(Fixture.now.timeIntervalSince1970) + 30
        let reply = StubTransport.Reply.json(
            403,
            #"{"message":"API rate limit exceeded"}"#,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]
        )
        // リセットの時刻ちょうどではまだ弾かれることがあるので、1 秒の余裕を持たせる
        #expect(await readError(reply) == .rateLimited(retryAfter: .seconds(31)))
    }

    @Test func retryAfterComesFirst() async {
        let reset = Int(Fixture.now.timeIntervalSince1970) + 600
        let reply = StubTransport.Reply.json(
            429,
            #"{"message":"too many"}"#,
            headers: ["Retry-After": "12", "x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"]
        )
        #expect(await readError(reply) == .rateLimited(retryAfter: .seconds(12)))
    }

    @Test func secondaryRateLimitWithoutHeadersWaitsAMinute() async {
        let message = #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#
        #expect(await readError(.json(403, message)) == .rateLimited(retryAfter: .seconds(60)))
        #expect(await readError(.json(429, "{}")) == .rateLimited(retryAfter: .seconds(60)))
    }

    @Test func forbiddenIsNotRateLimit() async {
        let reply = StubTransport.Reply.json(403, #"{"message":"Resource not accessible by personal access token"}"#)
        #expect(await readError(reply) == .forbidden(message: "Resource not accessible by personal access token"))
    }

    // MARK: - ほかの失敗

    @Test func classifiesStatusCodes() async {
        #expect(await readError(.json(401, #"{"message":"Bad credentials"}"#)) == .unauthorized)
        #expect(await readError(.json(404, #"{"message":"Not Found"}"#)) == .notFound)
        #expect(await readError(.json(409, #"{"message":"Conflict"}"#)) == .conflict(message: "Conflict"))
        #expect(await readError(.json(502, "<html>")) == .serverError(status: 502))
        #expect(await readError(.init(status: 301, headers: ["Location": "https://api.github.com/repositories/1"])) == .redirected(status: 301))
        #expect(await readError(.json(418, "{}")) == .unexpected(status: 418, message: nil))
    }

    @Test func malformedResponseIsReported() async {
        #expect(await readError(.json(200, #"{"number":"seven"}"#)) == .malformed("pulls/7 の応答を読めない"))
    }

    @Test func refusesNextPageOnAnotherHost() async throws {
        // 別のホストにトークンを送らない
        let transport = StubTransport([.json(200, "[]", headers: Fixture.link(next: "https://evil.example.com/pulls?page=2"))])
        await #expect(throws: PullRequestError.malformed("次のページの URL が API のホストと違う")) {
            try await Fixture.client(transport).openPullRequest(head: "feat/task-1", base: "epic/feature")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func stopsFollowingEndlessPages() async throws {
        let next = "https://api.github.com/repositories/1/pulls?page=2"
        let page = StubTransport.Reply.json(200, "[]", headers: Fixture.link(next: next))
        let replies = Array(repeating: page, count: GitHubAPI.maxPages + 1)
        let transport = StubTransport(replies)
        await #expect(throws: PullRequestError.malformed("pulls のページが \(GitHubAPI.maxPages) を超えた")) {
            try await Fixture.client(transport).openPullRequest(head: "feat/task-1", base: "epic/feature")
        }
        #expect(transport.requests.count == GitHubAPI.maxPages)
    }

    @Test func tokenFailureSendsNothing() async throws {
        struct KeychainMissing: Error {}
        let transport = StubTransport([])
        let client = GitHubPullRequests(repository: Fixture.repository, transport: transport) { throw KeychainMissing() }
        await #expect(throws: PullRequestError.tokenUnavailable) { try await client.pullRequest(number: 7) }
        #expect(transport.requests.isEmpty)
    }

    @Test func transportFailureHidesDetails() async throws {
        // StubTransport は応答が尽きると URLError を投げる
        let transport = StubTransport([])
        await #expect(throws: PullRequestError.transport("URLError \(URLError.badServerResponse.rawValue)")) {
            try await Fixture.client(transport).pullRequest(number: 7)
        }
    }

    @Test func errorsDoNotContainToken() async {
        let replies: [StubTransport.Reply] = [
            .json(401, #"{"message":"Bad credentials"}"#), .json(403, #"{"message":"forbidden"}"#), .json(422, #"{"message":"bad"}"#)
        ]
        for reply in replies {
            let error = await readError(reply)
            #expect(error != nil)
            #expect(!String(describing: error).contains(Fixture.token))
        }
    }

    @Test func linkHeaderPicksNext() {
        let header = #"<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="next""#
        #expect(LinkHeader.next(header)?.absoluteString == "https://api.github.com/x?page=3")
        #expect(LinkHeader.next(#"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(LinkHeader.next(nil) == nil)
    }
}
