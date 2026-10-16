@testable import AskHubKit
import Foundation
import os
import Testing

/// マージ待ちの取得で、Upload ワークフローの直近の run を PR に付ける（Discussion #449）
struct GitHubMergeQueueUploadStatusTests {
    private func makeQueue(_ http: MockHTTPClient, uploadWorkflow: (any UploadWorkflowProviding)? = nil) -> GitHubMergeQueue {
        let client = GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in })
        return GitHubMergeQueue(client: client, trustedAuthors: TrustedAuthors(["mrs1669"]), uploadWorkflow: uploadWorkflow)
    }

    /// 検索の結果の PR 1 件。GitHub Actions の CI は成功している
    private static func node(number: Int, author: String = "mrs1669", mergeable: String = "MERGEABLE") -> String {
        GitHubMergeQueueTests.node(
            number: number,
            author: author,
            mergeable: mergeable,
            contexts: GitHubMergeQueueTests.contexts([GitHubMergeQueueTests.checkRun("build / build")])
        )
    }

    private static func searchResponse(_ nodes: [String]) -> MockHTTPClient.Response {
        .init(status: 200, body: GitHubMergeQueueTests.searchPage(nodes))
    }

    @Test func leavesUploadStatusNotLoadedWithoutWorkflowProvider() async throws {
        let nodes = [Self.node(number: 1)]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let pulls = try await makeQueue(http).epicPullRequests(orgs: ["shilokuma-inc"])
        #expect(pulls.map(\.uploadStatus) == [.notLoaded])
    }

    @Test func attachesLatestUploadRunOncePerRepositoryAndBranch() async throws {
        // 1 と 2 は同じリポジトリの別の epic、3 は 1 と同じブランチ（取得を共有する）
        let node3 = Self.node(number: 3)
            .replacingOccurrences(of: #""headRefName": "epic/e3""#, with: #""headRefName": "epic/e1""#)
        let nodes = [
            Self.node(number: 1),
            Self.node(number: 2, mergeable: "CONFLICTING"),
            node3,
            // 信用しない author の PR では run を読まない
            Self.node(number: 4, author: "someone")
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
        let nodes = (1...4).map { Self.node(number: $0) }
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
        let node3 = Self.node(number: 3)
            .replacingOccurrences(of: #""nameWithOwner": "o/r""#, with: #""nameWithOwner": "o/other""#)
        let nodes = [
            Self.node(number: 1),
            Self.node(number: 2),
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
        let nodes = [Self.node(number: 1)]
        let http = MockHTTPClient([Self.searchResponse(nodes)])
        let workflow = RecordingUploadWorkflow(["o/r epic/e1": .failure(CancellationError())])
        await #expect(throws: CancellationError.self) {
            try await makeQueue(http, uploadWorkflow: workflow).epicPullRequests(orgs: ["shilokuma-inc"])
        }
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

    func dispatch(repository: String, ref: String) async throws {
        // マージ待ちの取得では起動しない
        Issue.record("dispatch should not be called: \(repository) \(ref)")
    }
}
