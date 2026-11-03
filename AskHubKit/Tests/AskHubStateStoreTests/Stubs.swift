import AskHubStateStore
import Foundation
import os

/// 決まった順に応答を返し、受けた要求を残す
final class StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Self {
            Self(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    private let state: OSAllocatedUnfairLock<(replies: [Reply], requests: [URLRequest])>

    init(_ replies: [Reply]) {
        state = OSAllocatedUnfairLock(initialState: (replies, []))
    }

    var requests: [URLRequest] {
        state.withLock { $0.requests }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state -> Reply? in
            state.requests.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (reply.body, response)
    }
}

/// 待たずに、待つはずだった時間を残す
final class RecordingSleeper: Sleeper {
    private let state = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var waits: [Duration] {
        state.withLock { $0 }
    }

    func sleep(for duration: Duration) async throws {
        state.withLock { $0.append(duration) }
    }
}
