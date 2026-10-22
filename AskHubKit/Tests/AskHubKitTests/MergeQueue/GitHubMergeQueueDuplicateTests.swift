@testable import AskHubKit
import Foundation
import Testing

/// マージ待ちの取得で、search のページングで同じ PR が 2 回来ても 1 つだけ出す
struct GitHubMergeQueueDuplicateTests {
    private typealias Fixture = GitHubMergeQueueTests

    @Test func keepsFirstOfPullRequestsListedOnTwoPages() async throws {
        // search のページングの途中で順位が動き、同じ PR が 1 ページ目と 2 ページ目の両方に出る
        let success = Fixture.contexts([Fixture.checkRun("build / build")])
        let firstPage = #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": true, "endCursor": "p1" }, "nodes": [
              \#(Fixture.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", contexts: success)),
              \#(Fixture.node(number: 2, author: "mrs1669", mergeable: "MERGEABLE", contexts: success))
            ] } } }
            """#
        let http = MockHTTPClient([
            .init(status: 200, body: firstPage),
            .init(status: 200, body: Fixture.searchPage([
                Fixture.node(number: 2, author: "mrs1669", mergeable: "CONFLICTING", contexts: success),
                Fixture.node(number: 3, author: "mrs1669", mergeable: "MERGEABLE", contexts: success)
            ]))
        ])
        let client = GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
        let pulls = try await GitHubMergeQueue(client: client, trustedAuthors: TrustedAuthors(["mrs1669"]))
            .epicPullRequests(orgs: ["shilokuma-inc"])
        #expect(pulls.map(\.id) == ["PR_1", "PR_2", "PR_3"])
        // 先に来た 1 ページ目のものを残す
        #expect(pulls[1].mergeability == .mergeable)
        #expect(http.requests.count == 2)
    }
}
