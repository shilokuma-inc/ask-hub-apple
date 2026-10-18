@testable import AskHubKit
import Foundation
import os
import Testing

struct GitHubDeviceFlowTests {
    /// 待った時間だけ進む時計
    private final class FakeClock: Sendable {
        private let state = OSAllocatedUnfairLock<(now: Date, slept: [Duration])>(
            initialState: (Date(timeIntervalSince1970: 1_000_000), [])
        )

        var now: Date {
            state.withLock { $0.now }
        }

        var slept: [Duration] {
            state.withLock { $0.slept }
        }

        func sleep(_ duration: Duration) {
            state.withLock {
                $0.now.addTimeInterval(TimeInterval(duration.components.seconds))
                $0.slept.append(duration)
            }
        }
    }

    private let clock = FakeClock()

    private func makeFlow(_ responses: [MockHTTPClient.Response], scope: String? = nil) -> (GitHubDeviceFlow, MockHTTPClient) {
        let http = MockHTTPClient(responses)
        let clock = clock
        let flow = GitHubDeviceFlow(
            clientID: "Iv1.abc",
            scope: scope,
            http: http,
            sleep: { clock.sleep($0) },
            now: { clock.now }
        )
        return (flow, http)
    }

    private static let codeBody = """
    {"device_code":"dev-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device",\
    "expires_in":900,"interval":5}
    """

    private static func body(of request: URLRequest) -> String {
        request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    @Test
    func startRequestsDeviceCode() async throws {
        let (flow, http) = makeFlow([.init(status: 200, body: Self.codeBody)], scope: "repo read:org")
        let authorization = try await flow.start()

        #expect(authorization.userCode == "WDJB-MJHT")
        #expect(authorization.verificationURI == URL(string: "https://github.com/login/device"))
        #expect(authorization.interval == .seconds(5))
        #expect(authorization.expiresAt == clock.now.addingTimeInterval(900))

        let request = try #require(http.requests.first)
        #expect(request.url == URL(string: "https://github.com/login/device/code"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(Self.body(of: request) == "client_id=Iv1.abc&scope=repo%20read%3Aorg")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func startOmitsScopeWhenNil() async throws {
        let (flow, http) = makeFlow([.init(status: 200, body: Self.codeBody)])
        _ = try await flow.start()
        #expect(Self.body(of: try #require(http.requests.first)) == "client_id=Iv1.abc")
    }

    @Test
    func startReportsDisabledDeviceFlow() async {
        let (flow, _) = makeFlow([.init(status: 400, body: #"{"error":"device_flow_disabled"}"#)])
        await #expect(throws: GitHubDeviceFlow.Failure.deviceFlowDisabled) {
            try await flow.start()
        }
    }

    @Test
    func startReportsHTTPStatusWithoutErrorBody() async {
        let (flow, _) = makeFlow([.init(status: 404, body: "Not Found")])
        await #expect(throws: GitHubDeviceFlow.Failure.http(status: 404)) {
            try await flow.start()
        }
    }

    @Test
    func startRejectsNonHTTPSVerificationURI() async {
        let body = #"{"device_code":"d","user_code":"u","verification_uri":"http://example.com","expires_in":900,"interval":5}"#
        let (flow, _) = makeFlow([.init(status: 200, body: body)])
        await #expect(throws: GitHubDeviceFlow.Failure.invalidResponse) {
            try await flow.start()
        }
    }

    @Test
    func waitPollsUntilAuthorized() async throws {
        let (flow, http) = makeFlow([
            .init(status: 200, body: Self.codeBody),
            .init(status: 200, body: #"{"error":"authorization_pending"}"#),
            .init(status: 200, body: #"{"error":"authorization_pending"}"#),
            .init(status: 200, body: #"{"access_token":"gho_secret","token_type":"bearer","scope":"repo"}"#)
        ])
        let authorization = try await flow.start()
        let token = try await flow.waitForToken(authorization)

        #expect(token == GitHubDeviceFlow.Token(accessToken: "gho_secret", scope: "repo"))
        #expect(clock.slept == [.seconds(5), .seconds(5), .seconds(5)])
        let poll = http.requests[1]
        #expect(poll.url == URL(string: "https://github.com/login/oauth/access_token"))
        let grantType = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        #expect(Self.body(of: poll) == "client_id=Iv1.abc&device_code=dev-123&grant_type=\(grantType)")
        #expect(poll.url?.query == nil)
    }

    @Test
    func slowDownUsesReturnedIntervalOrAddsFiveSeconds() async throws {
        let (flow, _) = makeFlow([
            .init(status: 200, body: Self.codeBody),
            .init(status: 200, body: #"{"error":"slow_down","interval":10}"#),
            .init(status: 200, body: #"{"error":"slow_down"}"#),
            .init(status: 200, body: #"{"access_token":"t"}"#)
        ])
        let authorization = try await flow.start()
        let token = try await flow.waitForToken(authorization)

        #expect(token.accessToken == "t")
        #expect(token.scope.isEmpty)
        #expect(clock.slept == [.seconds(5), .seconds(10), .seconds(15)])
    }

    @Test
    func waitStopsAtExpiredToken() async throws {
        let (flow, _) = makeFlow([
            .init(status: 200, body: Self.codeBody),
            .init(status: 200, body: #"{"error":"expired_token"}"#)
        ])
        let authorization = try await flow.start()
        await #expect(throws: GitHubDeviceFlow.Failure.expired) {
            try await flow.waitForToken(authorization)
        }
    }

    @Test
    func waitStopsAtAccessDenied() async throws {
        let (flow, _) = makeFlow([
            .init(status: 200, body: Self.codeBody),
            .init(status: 200, body: #"{"error":"access_denied"}"#)
        ])
        let authorization = try await flow.start()
        await #expect(throws: GitHubDeviceFlow.Failure.accessDenied) {
            try await flow.waitForToken(authorization)
        }
    }

    @Test
    func waitStopsWithoutRequestAfterLocalExpiry() async throws {
        let body = #"{"device_code":"d","user_code":"u","verification_uri":"https://github.com/login/device","expires_in":12,"interval":5}"#
        let (flow, http) = makeFlow([
            .init(status: 200, body: body),
            .init(status: 200, body: #"{"error":"authorization_pending"}"#),
            .init(status: 200, body: #"{"error":"authorization_pending"}"#)
        ])
        let authorization = try await flow.start()
        await #expect(throws: GitHubDeviceFlow.Failure.expired) {
            try await flow.waitForToken(authorization)
        }
        // 5 秒後・10 秒後は問い合わせ、15 秒後は期限切れで問い合わせない
        #expect(http.requests.count == 3)
    }

    @Test
    func waitReportsOtherOAuthErrors() async throws {
        let (flow, _) = makeFlow([
            .init(status: 200, body: Self.codeBody),
            .init(status: 200, body: #"{"error":"incorrect_device_code","error_description":"bad"}"#)
        ])
        let authorization = try await flow.start()
        await #expect(throws: GitHubDeviceFlow.Failure.oauth(code: "incorrect_device_code", description: "bad")) {
            try await flow.waitForToken(authorization)
        }
    }
}
