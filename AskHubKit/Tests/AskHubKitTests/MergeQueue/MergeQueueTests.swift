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

    /// GitHub Actions の check run（`statusCheckRollup.contexts` の 1 件）
    private static func checkRun(
        _ name: String,
        status: String = "COMPLETED",
        conclusion: String? = "SUCCESS",
        app: String? = "github-actions"
    ) -> String {
        let conclusionJSON = conclusion.map { #""\#($0)""# } ?? "null"
        // アプリが削除された check run では `app` が `null` になる
        let appJSON = app.map { #"{ "slug": "\#($0)" }"# } ?? "null"
        return #"""
            { "__typename": "CheckRun", "name": "\#(name)", "status": "\#(status)", "conclusion": \#(conclusionJSON),
              "checkSuite": { "app": \#(appJSON) } }
            """#
    }

    /// commit status（`statusCheckRollup.contexts` の 1 件）。既定は CodeRabbit のレビュー中
    private static func status(
        _ context: String = "CodeRabbit",
        state: String = "PENDING",
        description: String? = "Review in progress"
    ) -> String {
        let descriptionJSON = description.map { #""\#($0)""# } ?? "null"
        return #"{ "__typename": "StatusContext", "context": "\#(context)", "state": "\#(state)", "description": \#(descriptionJSON) }"#
    }

    /// `statusCheckRollup.contexts` の 1 ページ
    private static func contexts(_ nodes: [String], hasNextPage: Bool = false, endCursor: String? = nil) -> String {
        let cursorJSON = endCursor.map { #""\#($0)""# } ?? "null"
        let pageInfo = #"{ "hasNextPage": \#(hasNextPage), "endCursor": \#(cursorJSON) }"#
        return #"{ "pageInfo": \#(pageInfo), "nodes": [\#(nodes.joined(separator: ", "))] }"#
    }

    /// 検索の結果の PR 1 件。`contexts` が `nil` なら `statusCheckRollup` 自体が `null`（コミットにチェックが 1 つも無い）
    private static func node(
        number: Int,
        author: String,
        mergeable: String,
        contexts: String?,
        base: String = "develop",
        headRepository: String? = "o/r"
    ) -> String {
        let rollupJSON = contexts.map { #"{ "contexts": \#($0) }"# } ?? "null"
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

    private static func searchPage(_ nodes: [String]) -> String {
        #"""
        { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
          \#(nodes.joined(separator: ",\n"))
        ] } } }
        """#
    }

    private static func variables(of request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["variables"] as? [String: Any])
    }

    @Test func listsTrustedEpicFinalPullRequestsWithStatus() async throws {
        let success = Self.contexts([Self.checkRun("build / build"), Self.status(state: "SUCCESS", description: "Review completed")])
        let http = MockHTTPClient([
            .init(status: 200, body: Self.searchPage([
                Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", contexts: success),
                Self.node(number: 2, author: "MRS1669", mergeable: "CONFLICTING", contexts: Self.contexts([
                    Self.checkRun("build / build", status: "IN_PROGRESS", conclusion: nil)
                ])),
                Self.node(number: 3, author: "someone", mergeable: "MERGEABLE", contexts: success),
                Self.node(number: 4, author: "mrs1669", mergeable: "UNKNOWN", contexts: nil),
                Self.node(number: 5, author: "mrs1669", mergeable: "MERGEABLE", contexts: success, base: "epic/mvp"),
                Self.node(number: 6, author: "mrs1669", mergeable: "MERGEABLE", contexts: success, headRepository: "fork/r"),
                Self.node(number: 7, author: "mrs1669", mergeable: "MERGEABLE", contexts: success, headRepository: nil),
                "{}"
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        // 既定ブランチ以外への PR（5）・fork からの PR（6）・head のリポジトリが分からない PR（7）は除く
        #expect(pulls.map(\.number) == [1, 2, 4])
        #expect(pulls.map(\.checks) == [.success, .pending, .none])
        #expect(pulls.map(\.mergeability) == [.mergeable, .conflicting, .unknown])
        #expect(pulls.first?.headSHA == "sha1")
        let variables = try Self.variables(of: http.requests.first)
        #expect(variables["query"] as? String == "org:shilokuma-inc is:pr is:open label:epic-final")
        #expect(http.requests.count == 1)
    }

    @Test func decidesChecksFromGitHubActionsCheckRunsOnly() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: Self.searchPage([
                // CodeRabbit がレビュー中（commit status が PENDING）でも、GitHub Actions が成功なら成功
                Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build"), Self.checkRun("No AI Attribution"), Self.status()
                ])),
                // GitHub Actions が 1 つでも実行中なら実行中（CodeRabbit は完了）
                Self.node(number: 2, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build"), Self.checkRun("test", status: "QUEUED", conclusion: nil),
                    Self.status(state: "SUCCESS", description: "Review completed")
                ])),
                // 失敗が 1 つでもあれば、実行中があっても失敗
                Self.node(number: 3, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build", conclusion: "TIMED_OUT"), Self.checkRun("test", status: "IN_PROGRESS", conclusion: nil)
                ])),
                // GitHub Actions の check run が無ければ なし（CodeRabbit の commit status や、他のアプリの check run があっても）
                Self.node(number: 4, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.status(state: "SUCCESS", description: "Review rate limited"), Self.checkRun("lint", app: "some-other-app")
                ])),
                // contexts が空
                Self.node(number: 5, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([])),
                // NEUTRAL / SKIPPED は成功。他のアプリの失敗は見ない
                Self.node(number: 6, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build", conclusion: "NEUTRAL"), Self.checkRun("docs", conclusion: "SKIPPED"),
                    Self.checkRun("lint", conclusion: "FAILURE", app: "some-other-app")
                ])),
                // COMPLETED なのに conclusion が無い check run は失敗として扱う
                Self.node(number: 7, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build", conclusion: nil)
                ])),
                // push と pull_request で同じコミットに同名の check run が 2 件並ぶことがある。片方が失敗なら失敗
                Self.node(number: 8, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.checkRun("build / build", conclusion: "FAILURE"), Self.checkRun("build / build")
                ])),
                // description が無い commit status と、アプリが削除された（app が null の）check run もデコードできる
                Self.node(number: 9, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([
                    Self.status(description: nil), Self.checkRun("orphan", conclusion: "FAILURE", app: nil), Self.checkRun("build / build")
                ]))
            ]))
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.number) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(pulls.map(\.checks) == [.success, .pending, .failure, .none, .none, .success, .failure, .failure, .success])
        #expect(pulls[0].canMerge)
        #expect(pulls[3].blockingReason == "CI が実行されていません")
    }

    @Test func fetchesRemainingContextsWhenFirstPageIsNotLast() async throws {
        let http = MockHTTPClient([
            // 1 ページ目は成功だけだが、まだ続きがある
            .init(status: 200, body: Self.searchPage([
                Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts(
                    [Self.checkRun("build / build")], hasNextPage: true, endCursor: "c1"
                )),
                // 続きが無い PR は取り直さない
                Self.node(number: 2, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts([Self.checkRun("build / build")]))
            ])),
            // 2 ページ目も続きがあり、3 ページ目に失敗がある（検索で確認した head のコミットを指定して取る）
            .init(status: 200, body: #"""
                { "data": { "repository": { "object": { "statusCheckRollup":
                  { "contexts": \#(Self.contexts([Self.status()], hasNextPage: true, endCursor: "c2")) } } } } }
                """#),
            .init(status: 200, body: #"""
                { "data": { "repository": { "object": { "statusCheckRollup":
                  { "contexts": \#(Self.contexts([Self.checkRun("test", conclusion: "FAILURE")])) } } } } }
                """#)
        ])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.number) == [1, 2])
        #expect(pulls.map(\.checks) == [.failure, .success])
        #expect(http.requests.count == 3)
        let second = try Self.variables(of: http.requests[1])
        #expect(second["owner"] as? String == "o")
        #expect(second["name"] as? String == "r")
        #expect(second["oid"] as? String == "sha1")
        #expect(second["after"] as? String == "c1")
        let third = try Self.variables(of: http.requests[2])
        #expect(third["after"] as? String == "c2")
    }

    @Test func failsWhenNextPageHasNoCursor() async {
        // hasNextPage なのに endCursor が無いレスポンスは、1 ページ目だけで黙って決めずにエラーにする
        let http = MockHTTPClient([
            .init(status: 200, body: Self.searchPage([
                Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", contexts: Self.contexts(
                    [Self.checkRun("build / build")], hasNextPage: true
                ))
            ]))
        ])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])
        }
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
