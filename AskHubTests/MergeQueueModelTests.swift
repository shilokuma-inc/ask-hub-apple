@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

private extension UploadWorkflowRun {
    static func fixture(
        status: Status = .completed,
        conclusion: Conclusion? = .success,
        startedAt: Date = Date(timeIntervalSince1970: 900)
    ) -> Self {
        Self(
            id: 1,
            repository: "shilokuma-inc/ask-hub-apple",
            branch: "epic/mvp",
            headSHA: "0000000",
            status: status,
            conclusion: conclusion,
            event: "workflow_dispatch",
            startedAt: startedAt,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/1")!
        )
    }
}

/// `RecordingQueue` でマージを失敗させる方法
private enum MergeFailure: Sendable {
    case headChanged
    case branchNotDeleted
}

@MainActor
struct MergeQueueModelTests {
    /// マージした PR を記録する。失敗させることもできる
    private final class RecordingQueue: MergeQueueProviding {
        private let state = OSAllocatedUnfairLock<(merged: [Int], failure: MergeFailure?)>(initialState: ([], nil))

        var merged: [Int] {
            state.withLock { $0.merged }
        }

        func setFailure(_ failure: MergeFailure?) {
            state.withLock { $0.failure = failure }
        }

        func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
            let merged = state.withLock { $0.merged }
            return SampleMergeQueue.pullRequests.filter { !merged.contains($0.number) }
        }

        func merge(_ pullRequest: EpicPullRequest) async throws {
            try state.withLock { state in
                switch state.failure {
                case .headChanged:
                    throw GitHubError.http(status: 409, message: "Head branch was modified.")

                case .branchNotDeleted:
                    state.merged.append(pullRequest.number)
                    throw MergeQueueError.branchNotDeleted(pullRequest.headBranch)

                case nil:
                    state.merged.append(pullRequest.number)
                }
            }
        }
    }

    /// Upload の起動を記録する。失敗させることもできる
    private final class RecordingUploadWorkflow: UploadWorkflowProviding {
        private let state = OSAllocatedUnfairLock<(dispatched: [String], failure: UploadWorkflowError?)>(initialState: ([], nil))

        var dispatched: [String] {
            state.withLock { $0.dispatched }
        }

        func setFailure(_ failure: UploadWorkflowError?) {
            state.withLock { $0.failure = failure }
        }

        func latestRun(repository: String, branch: String) async throws -> LatestUploadRun {
            .noRuns
        }

        func dispatch(repository: String, ref: String) async throws {
            try state.withLock { state in
                if let failure = state.failure {
                    throw failure
                }
                state.dispatched.append("\(repository) \(ref)")
            }
        }
    }

    private func makeModel(
        token: String? = "github_pat_saved",
        queue: RecordingQueue,
        uploadWorkflow: RecordingUploadWorkflow = RecordingUploadWorkflow()
    ) -> MergeQueueModel {
        MergeQueueModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeProvider: { _ in queue },
            makeUploadWorkflow: { _ in uploadWorkflow },
            // テストでは取り直しを待たない
            dispatchRefreshDelay: .zero
        )
    }

    @Test func loadsEpicFinalPullRequests() async {
        let model = makeModel(queue: RecordingQueue())
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.pullRequests.map(\.number) == [50, 80, 120])
    }

    @Test func refreshIfStaleSkipsRecentRefresh() async throws {
        let model = makeModel(queue: RecordingQueue())
        await model.refreshIfStale()
        let lastRefreshed = try #require(model.lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval - 1))
        #expect(model.lastRefreshed == lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval))
        #expect(try #require(model.lastRefreshed) > lastRefreshed)
    }

    @Test func needsToken() async {
        let model = makeModel(token: nil, queue: RecordingQueue())
        await model.refresh()
        #expect(model.state == .needsToken)
    }

    @Test func mergesAndRemovesFromList() async throws {
        let queue = RecordingQueue()
        let model = makeModel(queue: queue)
        await model.refresh()
        try await model.merge(model.pullRequests[0])

        #expect(queue.merged == [50])
        #expect(model.pullRequests.map(\.number) == [80, 120])
    }

    @Test func doesNotShowMergedPullRequestBeforeSearchCatchesUp() async throws {
        // 検索への反映が遅れ、マージした PR がまだ返ってくる
        let model = MergeQueueModel(tokenStore: InMemoryTokenStore(token: "github_pat_saved")) { _ in SampleMergeQueue() }
        await model.refresh()
        try await model.merge(model.pullRequests[0])
        await model.refresh()

        #expect(model.pullRequests.map(\.number) == [80, 120])
    }

    @Test func keepsPullRequestWhenHeadChanged() async {
        let queue = RecordingQueue()
        queue.setFailure(.headChanged)
        let model = makeModel(queue: queue)
        await model.refresh()

        await #expect(throws: GitHubError.self) {
            try await model.merge(model.pullRequests[0])
        }
        #expect(model.pullRequests.count == 3)
        #expect(MergeQueueModel.message(for: GitHubError.http(status: 409, message: nil)) == "確認した後に PR が更新されました。内容を確かめ直してからマージしてください")
    }

    @Test func removesMergedPullRequestEvenIfBranchRemains() async {
        let queue = RecordingQueue()
        queue.setFailure(.branchNotDeleted)
        let model = makeModel(queue: queue)
        await model.refresh()

        await #expect(throws: MergeQueueError.branchNotDeleted("epic/mvp")) {
            try await model.merge(model.pullRequests[0])
        }
        // マージはできているので、一覧からは外す
        #expect(model.pullRequests.map(\.number) == [80, 120])
        let message = MergeQueueModel.message(for: MergeQueueError.branchNotDeleted("epic/mvp"))
        #expect(message == "マージしましたが、ブランチ epic/mvp を削除できませんでした。GitHub で削除してください")
    }

    @Test func describesUploadWorkflowErrorsWithPermissionGuidance() {
        // レート制限でない 403 は権限不足。設定画面への案内を付ける
        let denied = MergeQueueModel.message(for: UploadWorkflowError.permissionDenied)
        #expect(denied == "TestFlight に上げられませんでした。トークンに、このリポジトリの Actions の書き込み権限（Read and write）があるか確かめてください。"
            + "設定で権限を付けたトークンを保存し直してください")
        let notFound = MergeQueueModel.message(for: UploadWorkflowError.workflowNotFound)
        #expect(notFound == "TestFlight に上げられませんでした。このリポジトリに Upload ワークフロー（upload.yml）が無いか、Actions が無効か、トークンから見えません")
        let unsupported = MergeQueueModel.message(for: UploadWorkflowError.dispatchNotSupported(message: "No ref found for: epic/x"))
        #expect(unsupported.contains("workflow_dispatch"))
        #expect(unsupported.hasSuffix("（No ref found for: epic/x）"))
        #expect(!MergeQueueModel.message(for: UploadWorkflowError.dispatchNotSupported(message: nil)).hasSuffix("）"))
        // レート制限は今までどおりの文言
        #expect(MergeQueueModel.message(for: GitHubError.rateLimited(retryAfter: .seconds(30))).contains("レート制限中"))
    }

    // MARK: - TestFlight へのアップロード

    @Test func dispatchesUploadOnHeadBranchAndKeepsPendingUntilRunAppears() async throws {
        let workflow = RecordingUploadWorkflow()
        let model = makeModel(queue: RecordingQueue(), uploadWorkflow: workflow)
        await model.refresh()
        let target = model.pullRequests[0]
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(model.canUpload(target, now: now))
        #expect(model.uploadBlockingReason(target, now: now) == nil)

        try await model.upload(target, now: now)

        #expect(workflow.dispatched == ["shilokuma-inc/ask-hub-apple epic/mvp"])
        // run がまだ出ていないあいだは「起動した」状態で、もう一度は押せない
        #expect(model.isDispatchPending(target, now: now))
        #expect(!model.canUpload(target, now: now))
        #expect(model.uploadBlockingReason(target, now: now)?.contains("起動しました") == true)
        // 起動より後に始まった run が付けば終わる。古い run では終わらない
        var withOldRun = target
        withOldRun.uploadStatus = .run(.fixture(startedAt: now.addingTimeInterval(-60)))
        #expect(model.isDispatchPending(withOldRun, now: now))
        var withNewRun = target
        withNewRun.uploadStatus = .run(.fixture(status: .inProgress, conclusion: nil, startedAt: now.addingTimeInterval(5)))
        #expect(!model.isDispatchPending(withNewRun, now: now))
        #expect(model.uploadBlockingReason(withNewRun, now: now) == "同じ epic ブランチで Upload を実行中です")
        // 長く待っても run が出なければ押し直せる
        #expect(!model.isDispatchPending(target, now: now.addingTimeInterval(MergeQueueModel.dispatchPendingLimit + 1)))
    }

    @Test func hidesUploadButtonWhenDispatchIsNotSupported() async {
        let workflow = RecordingUploadWorkflow()
        workflow.setFailure(.dispatchNotSupported(message: "Workflow does not have 'workflow_dispatch' trigger"))
        let model = makeModel(queue: RecordingQueue(), uploadWorkflow: workflow)
        await model.refresh()
        let target = model.pullRequests[0]
        #expect(model.showsUploadButton(target))

        await #expect(throws: UploadWorkflowError.dispatchNotSupported(message: "Workflow does not have 'workflow_dispatch' trigger")) {
            try await model.upload(target)
        }
        // 422 のリポジトリでは以後ボタンを出さない。別のリポジトリには影響しない
        #expect(!model.showsUploadButton(target))
        #expect(model.uploadBlockingReason(target) == nil)
        #expect(model.showsUploadButton(model.pullRequests[1]))
        #expect(!model.isDispatchPending(target))
    }

    @Test func doesNotShowUploadButtonWithoutWorkflow() {
        let model = makeModel(queue: RecordingQueue())
        var pullRequest = SampleMergeQueue.pullRequests[0]
        pullRequest.uploadStatus = .unsupported
        #expect(!model.showsUploadButton(pullRequest))
        #expect(!model.canUpload(pullRequest))
        // CI が実行中の PR は、run が無くても押せない
        #expect(!model.canUpload(SampleMergeQueue.pullRequests[1]))
        #expect(model.uploadBlockingReason(SampleMergeQueue.pullRequests[1]) == "CI が終わっていません")
    }

    @Test func describesRunStates() {
        #expect(UploadRunSection.runText(.fixture(status: .queued, conclusion: nil)) == "実行中")
        #expect(UploadRunSection.runText(.fixture()) == "成功")
        #expect(UploadRunSection.runText(.fixture(conclusion: .failure)) == "失敗")
        #expect(UploadRunSection.runText(.fixture(conclusion: .cancelled)) == "キャンセル")
        #expect(UploadRunSection.runText(.fixture(conclusion: .other("timed_out"))) == "終了（timed_out）")
        #expect(UploadRunSection.runText(.fixture(conclusion: nil)) == "終了（結論なし）")
    }

    @Test func blockedPullRequestCannotBeMerged() {
        // サンプルの 2 件目は CI が実行中
        #expect(!SampleMergeQueue.pullRequests[1].canMerge)
        #expect(SampleMergeQueue.pullRequests[1].blockingReason == "CI が終わっていません")
    }
}
