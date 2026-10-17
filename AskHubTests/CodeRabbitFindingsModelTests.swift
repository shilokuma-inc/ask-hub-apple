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

    private struct UntrustedPoster: FinalPullRequestInstructionPosting {
        func post(fixing thread: CodeRabbitReviewThread, note: String, to pullRequest: EpicPullRequest) async throws -> URL {
            throw FinalPullRequestInstructionError.untrustedAccount("someone")
        }
    }

    @Test func postsInstructionForOneFinding() async throws {
        let mergeQueue = MergeQueueModel.sample()
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: SampleCodeRabbitThreads.pullRequestID))
        await model.load(using: mergeQueue)
        let row = try #require(model.rows.first)

        #expect(await model.instruct(fixing: row, note: "文言をそろえる", using: mergeQueue) == nil)
        #expect(model.instructed[row.id]?.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/pull/50#issuecomment-1")
        // ほかの指摘には投稿していない
        #expect(model.instructed.count == 1)

        // 補足でほかの指摘を指すと、1 件ずつの指示にならないので投稿しない
        let other = try #require(model.rows.last)
        let failure = await model.instruct(fixing: other, note: "#discussion_r1 も", using: mergeQueue)
        #expect(failure?.contains("ほかの指摘へのリンク") == true)
        #expect(model.instructed[other.id] == nil)
    }

    @Test func explainsWhyUntrustedAccountCannotInstruct() async throws {
        let mergeQueue = MergeQueueModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeProvider: { _ in SampleMergeQueue() },
            makeCodeRabbitThreads: { _ in SampleCodeRabbitThreads() },
            makeInstructionPoster: { _ in UntrustedPoster() }
        )
        let model = CodeRabbitFindingsModel(pullRequest: Self.pullRequest(id: SampleCodeRabbitThreads.pullRequestID))
        await model.load(using: mergeQueue)
        let row = try #require(model.rows.first)

        let failure = await model.instruct(fixing: row, note: "", using: mergeQueue)
        #expect(failure?.contains("@someone はこのリポジトリで信用する author ではない") == true)
        #expect(model.instructed.isEmpty)
    }
}
