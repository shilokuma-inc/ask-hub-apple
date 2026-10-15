import AskHubKit

extension MergeQueueModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> MergeQueueModel {
        MergeQueueModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeProvider: { _ in SampleMergeQueue() },
            makeUploadWorkflow: { _ in SampleUploadWorkflow() },
            dispatchRefreshDelay: .seconds(1)
        )
    }
}

/// デモモード・Preview・UI テスト用。Upload を起動したことにして GitHub には送らない（Discussion #449）
struct SampleUploadWorkflow: UploadWorkflowProviding {
    func latestRun(repository: String, branch: String) async throws -> LatestUploadRun {
        .noRuns
    }

    func dispatch(repository: String, ref: String) async throws {}
}
