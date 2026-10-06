@testable import AskHubKit
import Foundation
import Testing

extension EpicPullRequest {
    static func fixture(
        checks: ChecksState = .success,
        mergeability: Mergeability = .mergeable,
        author: String? = "mrs1669"
    ) -> Self {
        Self(
            id: "PR_50",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 50,
            title: "【FEAT】epic/mvp を develop に取り込む",
            body: "### 回答待ちの PR\n- なし",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/50")!,
            baseBranch: "develop",
            headBranch: "epic/mvp",
            headSHA: "abc123",
            author: author,
            checks: checks,
            mergeability: mergeability
        )
    }
}

struct EpicPullRequestTests {
    @Test func canMergeOnlyWhenChecksPassAndNoConflict() {
        #expect(EpicPullRequest.fixture().canMerge)
        #expect(EpicPullRequest.fixture().blockingReason == nil)
        #expect(EpicPullRequest.fixture(mergeability: .conflicting).blockingReason == "develop とコンフリクトしています")
        #expect(EpicPullRequest.fixture(checks: .failure).blockingReason == "CI が失敗しています")
        #expect(EpicPullRequest.fixture(checks: .pending).blockingReason == "CI が終わっていません")
        #expect(EpicPullRequest.fixture(checks: .none).blockingReason == "CI が実行されていません")
        #expect(!EpicPullRequest.fixture(mergeability: .unknown).canMerge)
        #expect(EpicPullRequest.fixture().filesURL.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/pull/50/files")
    }
}

struct GitHubMergeQueueTests {
    private func makeQueue(_ http: MockHTTPClient) -> GitHubMergeQueue {
        let client = GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
        return GitHubMergeQueue(client: client, trustedAuthors: TrustedAuthors(["mrs1669"]))
    }

    private static func node(
        number: Int,
        author: String,
        mergeable: String,
        rollup: String?,
        base: String = "develop",
        headRepository: String? = "o/r"
    ) -> String {
        let rollupJSON = rollup.map { #"{ "state": "\#($0)" }"# } ?? "null"
        let headJSON = headRepository.map { #"{ "nameWithOwner": "\#($0)" }"# } ?? "null"
        return #"""
            { "id": "PR_\#(number)", "number": \#(number), "title": "T\#(number)", "body": "まとめ", "url": "https://github.com/o/r/pull/\#(number)",
              "baseRefName": "\#(base)", "headRefName": "epic/e\#(number)", "headRefOid": "sha\#(number)", "mergeable": "\#(mergeable)",
              "author": { "login": "\#(author)" },
              "repository": { "nameWithOwner": "o/r", "defaultBranchRef": { "name": "develop" } },
              "headRepository": \#(headJSON),
              "commits": { "nodes": [{ "commit": { "statusCheckRollup": \#(rollupJSON) } }] } }
            """#
    }

    @Test func listsTrustedEpicFinalPullRequestsWithStatus() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
                  \#(Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS")),
                  \#(Self.node(number: 2, author: "MRS1669", mergeable: "CONFLICTING", rollup: "PENDING")),
                  \#(Self.node(number: 3, author: "someone", mergeable: "MERGEABLE", rollup: "SUCCESS")),
                  \#(Self.node(number: 4, author: "mrs1669", mergeable: "UNKNOWN", rollup: nil)),
                  \#(Self.node(number: 5, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS", base: "epic/mvp")),
                  \#(Self.node(number: 6, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS", headRepository: "fork/r")),
                  \#(Self.node(number: 7, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS", headRepository: nil)),
                  {}
                ] } } }
                """#)
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        // 既定ブランチ以外への PR（5）・fork からの PR（6）・head のリポジトリが分からない PR（7）は除く
        #expect(pulls.map(\.number) == [1, 2, 4])
        #expect(pulls.map(\.checks) == [.success, .pending, .none])
        #expect(pulls.map(\.mergeability) == [.mergeable, .conflicting, .unknown])
        #expect(pulls.first?.headSHA == "sha1")
        let data = try #require(http.requests.first?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(object["variables"] as? [String: Any])
        #expect(variables["query"] as? String == "org:shilokuma-inc is:pr is:open label:epic-final")
    }

    @Test func mergesWithMergeCommitAtConfirmedHeadAndDeletesBranch() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "merged": true, "sha": "m1", "message": "Pull Request successfully merged" }"#),
            .init(status: 204, body: "")
        ])
        try await makeQueue(http).merge(.fixture())

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "PUT /repos/shilokuma-inc/ask-hub-apple/pulls/50/merge",
            "DELETE /repos/shilokuma-inc/ask-hub-apple/git/refs/heads/epic/mvp"
        ])
        let data = try #require(http.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["merge_method": "merge", "sha": "abc123"])
    }

    @Test func refusesToMergeWhenBlocked() async {
        let http = MockHTTPClient([])
        await #expect(throws: MergeQueueError.notMergeable(reason: "CI が失敗しています")) {
            try await makeQueue(http).merge(.fixture(checks: .failure))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func reportsHeadChangedAfterConfirmation() async {
        // 確認した後に PR が更新されていると、GitHub は 409 で断る
        let message = "Head branch was modified. Review and try the merge again."
        let http = MockHTTPClient([.init(status: 409, body: #"{ "message": "\#(message)" }"#)])
        await #expect(throws: GitHubError.http(status: 409, message: message)) {
            try await makeQueue(http).merge(.fixture())
        }
        #expect(http.requests.count == 1)
    }

    @Test func reportsBranchThatCouldNotBeDeleted() async {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "merged": true }"#),
            .init(status: 422, body: #"{ "message": "Reference does not exist" }"#)
        ])
        await #expect(throws: MergeQueueError.branchNotDeleted("epic/mvp")) {
            try await makeQueue(http).merge(.fixture())
        }
    }
}
