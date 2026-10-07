@testable import AskHubKit
import Foundation
import Testing

struct LoopStarterTests {
    private func makeStarter(_ http: MockHTTPClient) -> GitHubLoopStarter {
        GitHubLoopStarter(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private func variables(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["variables"] as? [String: Any])
    }

    private let discussion = InboxSubject.fixture(kind: .discussion, nodeID: "D_12")

    @Test func addsExistingReadyLabelToDiscussion() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "data": { "repository": { "label": { "id": "LA_ready" } } } }"#),
            .init(status: 200, body: #"{ "data": { "addLabelsToLabelable": { "clientMutationId": null } } }"#)
        ])
        try await makeStarter(http).markReadyForLoop(discussion)

        #expect(http.requests.count == 2)
        let lookup = try variables(of: http.requests[0])
        #expect(lookup["owner"] as? String == "shilokuma-inc")
        #expect(lookup["name"] as? String == "ask-hub-apple")
        #expect(lookup["label"] as? String == "ready-for-loop")
        let mutation = try variables(of: http.requests[1])
        #expect(mutation["labelable"] as? String == "D_12")
        #expect(mutation["labels"] as? [String] == ["LA_ready"])
    }

    @Test func createsReadyLabelWhenMissing() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "data": { "repository": { "label": null } } }"#),
            .init(status: 201, body: #"{ "id": 1, "node_id": "LA_new", "name": "ready-for-loop" }"#),
            .init(status: 200, body: #"{ "data": { "addLabelsToLabelable": { "clientMutationId": null } } }"#)
        ])
        try await makeStarter(http).markReadyForLoop(discussion)

        #expect(http.requests[1].httpMethod == "POST")
        #expect(http.requests[1].url?.path() == "/repos/shilokuma-inc/ask-hub-apple/labels")
        #expect(try variables(of: http.requests[2])["labels"] as? [String] == ["LA_new"])
    }

    @Test func addsManualLoopLabelCreatingItWhenMissing() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "data": { "repository": { "label": null } } }"#),
            .init(status: 201, body: #"{ "id": 2, "node_id": "LA_manual", "name": "manual-loop" }"#),
            .init(status: 200, body: #"{ "data": { "addLabelsToLabelable": { "clientMutationId": null } } }"#)
        ])
        try await makeStarter(http).markManualLoop(discussion)

        #expect(try variables(of: http.requests[0])["label"] as? String == "manual-loop")
        let createdBody = try #require(http.requests[1].httpBody)
        let created = try #require(try JSONSerialization.jsonObject(with: createdBody) as? [String: Any])
        #expect(created["name"] as? String == "manual-loop")
        let mutation = try variables(of: http.requests[2])
        #expect(mutation["labelable"] as? String == "D_12")
        #expect(mutation["labels"] as? [String] == ["LA_manual"])
    }

    @Test func refusesPullRequest() async {
        await #expect(throws: LoopStartingError.notDiscussion) {
            try await makeStarter(MockHTTPClient([])).markReadyForLoop(.fixture(kind: .pullRequest))
        }
        await #expect(throws: LoopStartingError.notDiscussion) {
            try await makeStarter(MockHTTPClient([])).markManualLoop(.fixture(kind: .pullRequest))
        }
    }
}
