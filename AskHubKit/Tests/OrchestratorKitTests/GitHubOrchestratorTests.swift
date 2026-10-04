import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct GitHubOrchestratorTests {
    /// 登録した順に 200 のレスポンスを返し、送られたリクエストを記録する
    private final class StubHTTPClient: HTTPClient {
        private let state: OSAllocatedUnfairLock<(bodies: [String], requests: [URLRequest])>

        init(_ bodies: [String]) {
            state = OSAllocatedUnfairLock(initialState: (bodies, []))
        }

        var requests: [URLRequest] {
            state.withLock { $0.requests }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = try state.withLock { state in
                state.requests.append(request)
                guard !state.bodies.isEmpty else {
                    throw GitHubError.invalidResponse
                }
                return state.bodies.removeFirst()
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw GitHubError.invalidResponse
            }
            return (Data(body.utf8), response)
        }
    }

    private func makeGitHub(_ http: StubHTTPClient) -> GitHubOrchestrator {
        GitHubOrchestrator(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private func requestJSON(_ request: URLRequest) throws -> (query: String, variables: [String: Any]) {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (try #require(object["query"] as? String), try #require(object["variables"] as? [String: Any]))
    }

    private static let readyLabel = #"{ "id": "LA_1", "name": "ready-for-loop" }"#

    private static func discussion(id: String, number: Int, closed: Bool = false, labels: String = readyLabel) -> String {
        #"""
        { "id": "\#(id)", "number": \#(number), "title": "T\#(number)", "url": "https://github.com/o/r/discussions/\#(number)",
          "closed": \#(closed), "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" },
          "labels": { "nodes": [\#(labels)] } }
        """#
    }

    private static let otherAndCapitalizedReadyLabels = #"{ "id": "LA_X", "name": "bug" }, { "id": "LA_9", "name": "Ready-For-Loop" }"#

    @Test func searchesReadyDiscussionsAcrossPagesAndSkipsUnusableNodes() async throws {
        let http = StubHTTPClient([
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": true, "endCursor": "S1" }, "nodes": [
              \#(Self.discussion(id: "D_1", number: 1)),
              {},
              \#(Self.discussion(id: "D_2", number: 2, closed: true))
            ] } } }
            """#,
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
              \#(Self.discussion(id: "D_3", number: 3, labels: Self.otherAndCapitalizedReadyLabels)),
              \#(Self.discussion(id: "D_4", number: 4, labels: "")),
              null
            ] } } }
            """#
        ])
        let discussions = try await makeGitHub(http).readyForLoopDiscussions(org: "shilokuma-inc")

        #expect(discussions.map(\.nodeID) == ["D_1", "D_3"])
        #expect(discussions.map(\.readyLabelID) == ["LA_1", "LA_9"])
        #expect(discussions.first?.author == "mrs1669")
        #expect(discussions.first?.repository == "o/r")
        let first = try requestJSON(http.requests[0])
        #expect(first.variables["query"] as? String == "org:shilokuma-inc label:ready-for-loop is:open")
        #expect(first.variables["after"] is NSNull)
        #expect(try requestJSON(http.requests[1]).variables["after"] as? String == "S1")
    }

    @Test func removesReadyLabelByNodeIDs() async throws {
        let http = StubHTTPClient([#"{ "data": { "removeLabelsFromLabelable": { "clientMutationId": null } } }"#])
        try await makeGitHub(http).removeReadyLabel(from: .fixture(number: 5))

        let request = try requestJSON(http.requests[0])
        #expect(request.query.contains("removeLabelsFromLabelable"))
        #expect(request.variables["labelable"] as? String == "D_5")
        #expect(request.variables["labels"] as? [String] == ["LA_ready"])
    }

    @Test func removeLabelReportsGraphQLErrors() async {
        let http = StubHTTPClient([#"{ "data": null, "errors": [{ "message": "Resource not accessible" }] }"#])
        await #expect(throws: GitHubError.graphQL(messages: ["Resource not accessible"])) {
            try await makeGitHub(http).removeReadyLabel(from: .fixture())
        }
    }
}
