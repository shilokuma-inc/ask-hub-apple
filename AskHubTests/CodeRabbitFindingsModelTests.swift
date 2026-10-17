@testable import AskHub
import AskHubKit
import Foundation
import Testing

@MainActor
struct CodeRabbitFindingsModelTests {
    private struct FailingThreads: CodeRabbitThreadsFetching {
        func unresolvedCodeRabbitThreads(of pullRequest: EpicPullRequest) async throws -> [CodeRabbitReviewThread] {
            throw GitHubError.http(status: 502, message: nil)
        }
    }

    private static func pullRequest(id: String) -> EpicPullRequest {
        EpicPullRequest(
            id: id,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 50,
            title: "【FEAT】epic/mvp を develop に取り込む",
            body: "",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/50")!,
            baseBranch: "develop",
            headBranch: "epic/mvp",
            headSHA: "abc",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable
        )
    }

    @Test func loadsSampleFindingsOfFinalPullRequest() async {
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: SampleCodeRabbitThreads.pullRequestID))
        await model.load(using: .sample())

        #expect(model.state == .loaded)
        #expect(model.rows.map(\.location) == ["AskHubKit/Sources/AskHubKit/GitHub/GitHubClient.swift:128", "AskHub/MergeQueueViews.swift"])
        #expect(model.rows.map(\.thread.summary) == ["レート制限の待ち時間に上限がありません", "見出しの文言をほかの画面にそろえる"])
        #expect(model.rows.allSatisfy { !$0.renderedBody.blocks.isEmpty })
    }

    @Test func loadsNoFindingsForOtherPullRequests() async {
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: "PR_other"))
        await model.load(using: .sample())
        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
    }

    @Test func reportsFailure() async {
        let mergeQueue = MergeQueueModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeProvider: { _ in SampleMergeQueue() },
            makeCodeRabbitThreads: { _ in FailingThreads() }
        )
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: "PR_50"))
        await model.load(using: mergeQueue)

        guard case .failed = model.state else {
            Issue.record("失敗として表示されていません: \(model.state)")
            return
        }
        #expect(model.rows.isEmpty)
    }

    @Test func failsWithoutToken() async {
        let mergeQueue = MergeQueueModel(tokenStore: InMemoryTokenStore(token: nil), makeProvider: { _ in SampleMergeQueue() })
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: "PR_50"))
        await model.load(using: mergeQueue)
        guard case .failed = model.state else {
            Issue.record("失敗として表示されていません: \(model.state)")
            return
        }
    }
}
