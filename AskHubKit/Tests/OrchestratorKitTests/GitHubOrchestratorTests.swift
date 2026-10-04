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

    @Test func removesNeedsAnswerByLookingUpLabelID() async throws {
        let http = StubHTTPClient([
            #"{ "data": { "repository": { "label": { "id": "LA_needs" } } } }"#,
            #"{ "data": { "removeLabelsFromLabelable": { "clientMutationId": null } } }"#
        ])
        let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_7",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 7,
            title: "T",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/7")!
        )
        try await makeGitHub(http).removeNeedsAnswerLabel(from: subject)

        let lookup = try requestJSON(http.requests[0])
        #expect(lookup.variables["owner"] as? String == "shilokuma-inc")
        #expect(lookup.variables["name"] as? String == "ask-hub-apple")
        #expect(lookup.variables["label"] as? String == "needs-answer")
        let mutation = try requestJSON(http.requests[1])
        #expect(mutation.variables["labelable"] as? String == "D_7")
        #expect(mutation.variables["labels"] as? [String] == ["LA_needs"])
    }

    @Test func skipsMutationWhenRepositoryHasNoNeedsAnswerLabel() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": { "label": null } } }"#])
        let subject = InboxSubject(
            kind: .pullRequest,
            nodeID: "PR_1",
            repository: "o/r",
            number: 1,
            title: "T",
            url: URL(string: "https://github.com/o/r/pull/1")!
        )
        try await makeGitHub(http).removeNeedsAnswerLabel(from: subject)
        #expect(http.requests.count == 1)
    }

    @Test func findsPullRequestsOfAnyStateByHeadPreferringOpen() async throws {
        let http = StubHTTPClient([
            "[]",
            #"[{ "number": 7, "state": "closed" }]"#,
            #"[{ "number": 7, "state": "closed" }, { "number": 9, "state": "open" }]"#
        ])
        let github = makeGitHub(http)
        let repository = "shilokuma-inc/ask-hub-apple"
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == nil)
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == ExistingPullRequest(number: 7, isOpen: false))
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == ExistingPullRequest(number: 9, isOpen: true))

        let url = try #require(http.requests[0].url)
        #expect(url.path() == "/repos/shilokuma-inc/ask-hub-apple/pulls")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "head", value: "shilokuma-inc:epic/mvp")))
        #expect(query.contains(URLQueryItem(name: "state", value: "all")))
    }

    @Test func createsEpicFinalPullRequestToDefaultBranchWithLabel() async throws {
        let http = StubHTTPClient([
            #"{ "default_branch": "develop" }"#,
            #"{ "number": 42, "state": "open" }"#,
            #"[{ "name": "epic-final" }]"#
        ])
        let github = makeGitHub(http)
        let number = try await github.createEpicFinalPullRequest(in: "o/r", head: "epic/mvp", body: "まとめ")
        #expect(number == 42)
        try await github.addEpicFinalLabel(in: "o/r", number: number)

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /repos/o/r",
            "POST /repos/o/r/pulls",
            "POST /repos/o/r/issues/42/labels"
        ])
        let pullBody = try #require(http.requests[1].httpBody)
        let pull = try #require(try JSONSerialization.jsonObject(with: pullBody) as? [String: String])
        #expect(pull["title"] == "【FEAT】epic/mvp を develop に取り込む")
        #expect(pull["head"] == "epic/mvp")
        #expect(pull["base"] == "develop")
        #expect(pull["body"]?.hasPrefix("まとめ\n\n---\n") == true)
        let labelsBody = try #require(http.requests[2].httpBody)
        let labels = try #require(try JSONSerialization.jsonObject(with: labelsBody) as? [String: [String]])
        #expect(labels == ["labels": ["epic-final"]])
    }

    @Test func removeLabelReportsGraphQLErrors() async {
        let http = StubHTTPClient([#"{ "data": null, "errors": [{ "message": "Resource not accessible" }] }"#])
        await #expect(throws: GitHubError.graphQL(messages: ["Resource not accessible"])) {
            try await makeGitHub(http).removeReadyLabel(from: .fixture())
        }
    }
}
