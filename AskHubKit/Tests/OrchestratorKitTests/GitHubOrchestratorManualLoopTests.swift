import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 手で回す Discussion（manual-loop）の検索
extension GitHubOrchestratorTests {
    @Test func searchesOpenManualLoopDiscussionsAcrossPages() async throws {
        let http = StubHTTPClient([
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": true, "endCursor": "S1" }, "nodes": [
              { "number": 1, "closed": false, "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" } },
              {},
              { "number": 2, "closed": true, "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" } }
            ] } } }
            """#,
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
              { "number": 3, "closed": false, "author": null, "repository": { "nameWithOwner": "o/r2" } },
              null
            ] } } }
            """#
        ])
        let discussions = try await makeGitHub(http).manualLoopDiscussions(orgs: ["shilokuma-inc", "BeaconFun4"])

        #expect(discussions == [
            ManualLoopDiscussion(repository: "o/r", number: 1, author: "mrs1669"),
            ManualLoopDiscussion(repository: "o/r2", number: 3, author: nil)
        ])
        let first = try requestJSON(http.requests[0])
        #expect(first.variables["query"] as? String == "org:shilokuma-inc org:BeaconFun4 label:manual-loop is:open")
        #expect(try requestJSON(http.requests[1]).variables["after"] as? String == "S1")
        #expect(http.requests.count == 2)
    }

    @Test func skipsSearchWithoutOrganizations() async throws {
        let http = StubHTTPClient([])
        #expect(try await makeGitHub(http).manualLoopDiscussions(orgs: []).isEmpty)
        #expect(http.requests.isEmpty)
    }
}
