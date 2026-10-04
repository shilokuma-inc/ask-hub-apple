@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

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

        func epicPullRequests(org: String) async throws -> [EpicPullRequest] {
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

    private func makeModel(token: String? = "github_pat_saved", queue: RecordingQueue) -> MergeQueueModel {
        MergeQueueModel(tokenStore: InMemoryTokenStore(token: token)) { _ in queue }
    }

    @Test func loadsEpicFinalPullRequests() async {
        let model = makeModel(queue: RecordingQueue())
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.pullRequests.map(\.number) == [50, 80])
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
        #expect(model.pullRequests.map(\.number) == [80])
    }

    @Test func doesNotShowMergedPullRequestBeforeSearchCatchesUp() async throws {
        // 検索への反映が遅れ、マージした PR がまだ返ってくる
        let model = MergeQueueModel(tokenStore: InMemoryTokenStore(token: "github_pat_saved")) { _ in SampleMergeQueue() }
        await model.refresh()
        try await model.merge(model.pullRequests[0])
        await model.refresh()

        #expect(model.pullRequests.map(\.number) == [80])
    }

    @Test func keepsPullRequestWhenHeadChanged() async {
        let queue = RecordingQueue()
        queue.setFailure(.headChanged)
        let model = makeModel(queue: queue)
        await model.refresh()

        await #expect(throws: GitHubError.self) {
            try await model.merge(model.pullRequests[0])
        }
        #expect(model.pullRequests.count == 2)
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
        #expect(model.pullRequests.map(\.number) == [80])
        let message = MergeQueueModel.message(for: MergeQueueError.branchNotDeleted("epic/mvp"))
        #expect(message == "マージしましたが、ブランチ epic/mvp を削除できませんでした。GitHub で削除してください")
    }

    @Test func blockedPullRequestCannotBeMerged() {
        // サンプルの 2 件目は CI が実行中
        #expect(!SampleMergeQueue.pullRequests[1].canMerge)
        #expect(SampleMergeQueue.pullRequests[1].blockingReason == "CI が終わっていません")
    }
}
