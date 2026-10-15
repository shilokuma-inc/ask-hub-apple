@testable import AskHubKit
import Foundation
import os
import Testing

extension EpicPullRequest {
    static func fixture(
        checks: ChecksState = .success,
        mergeability: Mergeability = .mergeable,
        author: String? = "mrs1669",
        uploadStatus: UploadStatus = .notLoaded
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
            mergeability: mergeability,
            uploadStatus: uploadStatus
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

    @Test func canUploadWhenChecksPassAndNoRunningRun() {
        // CI が成功していれば、コンフリクトしていても run が無くても上げられる
        #expect(EpicPullRequest.fixture(mergeability: .conflicting, uploadStatus: .noRuns).canUpload)
        #expect(EpicPullRequest.fixture(uploadStatus: .noRuns).uploadBlockingReason == nil)
        #expect(EpicPullRequest.fixture(uploadStatus: .run(.fixture())).canUpload)
        // 実行中の run があるあいだは押せない
        let running = EpicPullRequest.fixture(uploadStatus: .run(.fixture(status: .inProgress, conclusion: nil)))
        #expect(!running.canUpload)
        #expect(running.uploadBlockingReason == "同じ epic ブランチで Upload を実行中です")
        // CI の条件はマージボタンと同じ
        #expect(EpicPullRequest.fixture(checks: .pending, uploadStatus: .noRuns).uploadBlockingReason == "CI が終わっていません")
        #expect(EpicPullRequest.fixture(checks: .failure, uploadStatus: .noRuns).uploadBlockingReason == "CI が失敗しています")
        #expect(EpicPullRequest.fixture(checks: .none, uploadStatus: .noRuns).uploadBlockingReason == "CI が実行されていません")
        // ワークフローが無いリポジトリではボタンを出さない（理由も出さない）
        let unsupported = EpicPullRequest.fixture(uploadStatus: .unsupported)
        #expect(!unsupported.uploadStatus.showsUploadButton)
        #expect(!unsupported.canUpload)
        #expect(unsupported.uploadBlockingReason == nil)
        // 読んでいない・権限不足・取得できなかったときはボタンは出す（押した結果で分かる）
        #expect(EpicPullRequest.fixture().canUpload)
        #expect(EpicPullRequest.fixture(uploadStatus: .permissionDenied).canUpload)
        #expect(EpicPullRequest.fixture(uploadStatus: .unavailable).canUpload)
    }

    @Test func reportsWhetherLatestHeadWasUploaded() {
        #expect(EpicPullRequest.fixture().uploadedLatestHead == nil)
        #expect(EpicPullRequest.fixture(uploadStatus: .run(.fixture(headSHA: "abc123"))).uploadedLatestHead == true)
        #expect(EpicPullRequest.fixture(uploadStatus: .run(.fixture(headSHA: "old"))).uploadedLatestHead == false)
        #expect(EpicPullRequest.fixture(uploadStatus: .run(.fixture())).uploadStatus.run == .fixture())
    }
}

/// 呼ばれた（リポジトリ, ブランチ）を記録し、登録した結果を返す `UploadWorkflowProviding`
private final class RecordingUploadWorkflow: UploadWorkflowProviding {
    private struct State {
        var results: [String: Result<LatestUploadRun, any Error>]
        var calls: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ results: [String: Result<LatestUploadRun, any Error>]) {
        state = OSAllocatedUnfairLock(initialState: State(results: results))
    }

    var recordedCalls: [String] {
        state.withLock { $0.calls }
    }

    func latestRun(repository: String, branch: String) async throws -> LatestUploadRun {
        let key = "\(repository) \(branch)"
        let result = state.withLock { state -> Result<LatestUploadRun, any Error>? in
            state.calls.append(key)
            return state.results[key]
        }
        guard let result else {
            throw GitHubError.invalidResponse
        }
        return try result.get()
    }
}

struct GitHubMergeQueueTests {
    private func makeQueue(_ http: MockHTTPClient, uploadWorkflow: (any UploadWorkflowProviding)? = nil) -> GitHubMergeQueue {
        let client = GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
        return GitHubMergeQueue(client: client, trustedAuthors: TrustedAuthors(["mrs1669"]), uploadWorkflow: uploadWorkflow)
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

    private static func searchResponse(_ nodes: [String]) -> MockHTTPClient.Response {
        let body = #"{ "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [ "#
            + nodes.joined(separator: ",") + " ] } } }"
        return .init(status: 200, body: body)
    }

    @Test func leavesUploadStatusNotLoadedWithoutWorkflowProvider() async throws {
        let nodes = [Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS")]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])
        #expect(pulls.map(\.uploadStatus) == [.notLoaded])
    }

    @Test func attachesLatestUploadRunOncePerRepositoryAndBranch() async throws {
        // 1 と 2 は同じリポジトリの別の epic、3 は 1 と同じブランチ（取得を共有する）
        let node3 = Self.node(number: 3, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS")
            .replacingOccurrences(of: #""headRefName": "epic/e3""#, with: #""headRefName": "epic/e1""#)
        let nodes = [
            Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS"),
            Self.node(number: 2, author: "mrs1669", mergeable: "CONFLICTING", rollup: "SUCCESS"),
            node3,
            // 信用しない author の PR では run を読まない
            Self.node(number: 4, author: "someone", mergeable: "MERGEABLE", rollup: "SUCCESS")
        ]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let run = UploadWorkflowRun.fixture(headSHA: "sha1")
        let workflow = RecordingUploadWorkflow([
            "o/r epic/e1": .success(.run(run)),
            "o/r epic/e2": .success(.noRuns)
        ])
        let pulls = try await makeQueue(http, uploadWorkflow: workflow).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.number) == [1, 2, 3])
        #expect(pulls.map(\.uploadStatus) == [.run(run), .noRuns, .run(run)])
        #expect(pulls.map(\.uploadedLatestHead) == [true, nil, false])
        // コンフリクトしていても CI が成功していれば上げられる
        #expect(pulls[1].canUpload)
        #expect(workflow.recordedCalls == ["o/r epic/e1", "o/r epic/e2"])
    }

    @Test func keepsPullRequestsWhenUploadRunCannotBeRead() async throws {
        let nodes = (1...4).map { Self.node(number: $0, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS") }
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let workflow = RecordingUploadWorkflow([
            "o/r epic/e1": .failure(UploadWorkflowError.permissionDenied),
            "o/r epic/e2": .failure(GitHubError.invalidResponse),
            "o/r epic/e3": .failure(GitHubError.rateLimited(retryAfter: .seconds(60)))
            // e4 は、レート制限で待てなくなった後なので読まない
        ])
        let pulls = try await makeQueue(http, uploadWorkflow: workflow).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.number) == [1, 2, 3, 4])
        #expect(pulls.map(\.uploadStatus) == [.permissionDenied, .unavailable, .unavailable, .unavailable])
        #expect(pulls.map(\.canMerge) == [true, true, true, true])
        #expect(pulls.map(\.canUpload) == [true, true, true, true])
        #expect(workflow.recordedCalls == ["o/r epic/e1", "o/r epic/e2", "o/r epic/e3"])
    }

    @Test func skipsOtherBranchesOfRepositoryWithoutWorkflow() async throws {
        // ワークフローが無い（404）のはリポジトリの性質なので、同じリポジトリの別の epic は読まない
        let node3 = Self.node(number: 3, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS")
            .replacingOccurrences(of: #""nameWithOwner": "o/r""#, with: #""nameWithOwner": "o/other""#)
        let nodes = [
            Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS"),
            Self.node(number: 2, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS"),
            node3
        ]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let workflow = RecordingUploadWorkflow([
            "o/r epic/e1": .success(.unsupported),
            "o/other epic/e3": .success(.noRuns)
        ])
        let pulls = try await makeQueue(http, uploadWorkflow: workflow).epicPullRequests(orgs: ["shilokuma-inc"])

        #expect(pulls.map(\.uploadStatus) == [.unsupported, .unsupported, .noRuns])
        #expect(workflow.recordedCalls == ["o/r epic/e1", "o/other epic/e3"])
    }

    @Test func propagatesCancellationWhileReadingUploadRuns() async throws {
        // 取得が打ち切られたときは unavailable で確定させず、呼び出し側（MergeQueueModel）が前の状態に戻せるよう投げる
        let nodes = [Self.node(number: 1, author: "mrs1669", mergeable: "MERGEABLE", rollup: "SUCCESS")]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let workflow = RecordingUploadWorkflow(["o/r epic/e1": .failure(CancellationError())])
        await #expect(throws: CancellationError.self) {
            try await makeQueue(http, uploadWorkflow: workflow).epicPullRequests(orgs: ["shilokuma-inc"])
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
