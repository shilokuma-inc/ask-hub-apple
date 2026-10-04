@testable import AskHubKit
import Foundation
import os

/// 登録した順にレスポンスを返し、送られたリクエストを記録する `HTTPClient`
final class MockHTTPClient: HTTPClient {
    struct Response {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private struct State {
        var responses: [Response]
        var requests: [URLRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ responses: [Response]) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try state.withLock { state in
            state.requests.append(request)
            guard !state.responses.isEmpty else {
                throw GitHubError.invalidResponse
            }
            return state.responses.removeFirst()
        }
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: response.headers) else {
            throw GitHubError.invalidResponse
        }
        return (Data(response.body.utf8), http)
    }
}

/// 待った時間を記録するだけで、実際には待たない
final class SleepRecorder: Sendable {
    private let durations = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var recorded: [Duration] {
        durations.withLock { $0 }
    }

    func sleep(_ duration: Duration) {
        durations.withLock { $0.append(duration) }
    }
}
