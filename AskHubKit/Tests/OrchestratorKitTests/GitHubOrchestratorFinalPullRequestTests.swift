import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR（epic-final）の一覧

extension GitHubOrchestratorTests {
    @Test func listsOpenEpicFinalPullRequests() async throws {
        let http = StubHTTPClient([
            #"""
            [{ "number": 61, "head": { "ref": "epic/mvp" }, "user": { "login": "mrs1669" }, "labels": [{ "name": "epic-final" }] },
             { "number": 62, "head": { "ref": "feat/x" }, "user": { "login": "mrs1669" }, "labels": [] },
             { "number": 63, "head": { "ref": "epic/old" }, "user": null, "labels": [{ "name": "bug" }, { "name": "epic-final" }] }]
            """#
        ])
        let pulls = try await makeGitHub(http).epicFinalPullRequests(in: "o/r")

        #expect(pulls == [
            EpicFinalPullRequest(repository: "o/r", number: 61, headBranch: "epic/mvp", author: "mrs1669"),
            EpicFinalPullRequest(repository: "o/r", number: 63, headBranch: "epic/old", author: nil)
        ])
        let url = try #require(http.requests.first?.url)
        #expect(url.path() == "/repos/o/r/pulls")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "state", value: "open")))
    }
}
