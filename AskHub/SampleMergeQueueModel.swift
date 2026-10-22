import AskHubKit
import Foundation

extension MergeQueueModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> MergeQueueModel {
        MergeQueueModel(
            tokenStore: InMemoryTokenStore(token: "sample"),
            makeProvider: { _ in SampleMergeQueue.launchDefault() },
            makeUploadWorkflow: { _ in SampleUploadWorkflow() },
            dispatchRefreshDelay: .seconds(1),
            makeCodeRabbitThreads: { _ in SampleCodeRabbitThreads() },
            makeInstructionPoster: { _ in SampleFinalInstructionPoster() }
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

/// デモモード・Preview・UI テスト用。ask-hub-apple の最終 PR（PR_50）に CodeRabbit の未解決の指摘が 2 件ある（ほかの PR には無い）
struct SampleCodeRabbitThreads: CodeRabbitThreadsFetching {
    static let pullRequestID = "PR_50"

    func unresolvedCodeRabbitThreads(of pullRequest: EpicPullRequest) async throws -> [CodeRabbitReviewThread] {
        guard pullRequest.id == Self.pullRequestID else {
            return []
        }
        let url = pullRequest.url.absoluteString
        let now = Date()
        return [
            CodeRabbitReviewThread(
                id: "PRRT_1",
                path: "AskHubKit/Sources/AskHubKit/GitHub/GitHubClient.swift",
                line: 128,
                isOutdated: false,
                finding: .init(
                    id: 2_412_345_678,
                    author: "coderabbitai",
                    body: """
                        _⚠️ Potential issue_ | _🟠 Major_

                        **レート制限の待ち時間に上限がありません**

                        `Retry-After` が大きいと、取得が長く止まります。上限を設けてエラーにしてください。
                        """,
                    url: URL(string: "\(url)#discussion_r2412345678")!,
                    createdAt: now.addingTimeInterval(-3 * 60 * 60)
                )
            ),
            CodeRabbitReviewThread(
                id: "PRRT_2",
                path: "AskHub/MergeQueueViews.swift",
                line: nil,
                isOutdated: true,
                finding: .init(
                    id: 2_412_345_999,
                    author: "coderabbitai",
                    body: "_🧹 Nitpick_ | _🔵 Trivial_\n\n**見出しの文言をほかの画面にそろえる**\n\n「マージ待ち」の表記を統一してください。",
                    url: URL(string: "\(url)#discussion_r2412345999")!,
                    createdAt: now.addingTimeInterval(-2 * 60 * 60)
                ),
                replies: [
                    .init(
                        id: 2_412_346_000,
                        author: "mrs1669",
                        body: "最終 PR で直します",
                        url: URL(string: "\(url)#discussion_r2412346000")!,
                        createdAt: now.addingTimeInterval(-60 * 60)
                    )
                ]
            )
        ]
    }
}

/// デモモード・Preview・UI テスト用。指示を投稿したことにして GitHub には送らない（本文の組み立てと確かめは本物と同じ）
struct SampleFinalInstructionPoster: FinalPullRequestInstructionPosting {
    func post(fixing thread: CodeRabbitReviewThread, note: String, to pullRequest: EpicPullRequest) async throws -> URL {
        guard FinalPullRequestInstruction.body(for: thread, note: note) != nil else {
            throw FinalPullRequestInstructionError.invalidInstruction
        }
        return URL(string: "\(pullRequest.url.absoluteString)#issuecomment-1")!
    }
}
