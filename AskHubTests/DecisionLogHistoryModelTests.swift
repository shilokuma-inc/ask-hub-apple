@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 任意判断の詳細画面の、指示とループの返信の履歴（Discussion #349）
@MainActor
struct DecisionLogHistoryModelTests {
    private static let issue = InboxIssue(
        id: "I_9",
        kind: .decisionLog,
        repository: "o/r",
        number: 9,
        title: "【CHORE】epic/x の仮決め一覧",
        url: URL(string: "https://github.com/o/r/issues/9")!,
        author: "mrs1669",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    /// 決めたコメントを返す。`failure` を渡すと失敗する
    private struct Fetcher: DecisionLogCommentsFetching {
        var comments: [IssueComment] = []
        var failure: GitHubError?

        func comments(of issue: InboxIssue) async throws -> [IssueComment] {
            if let failure {
                throw failure
            }
            return comments
        }
    }

    /// リポジトリごとに信用する author を返し、問い合わせたリポジトリを記録する
    private final class Trust: TrustedAuthorsResolving {
        let asked = OSAllocatedUnfairLock<[String]>(initialState: [])

        func trustedAuthors(for repository: String) async -> TrustedAuthors {
            asked.withLock { $0.append(repository) }
            return repository == "o/r" ? TrustedAuthors(["mrs1669", "partner"]) : .default
        }
    }

    private static func inbox(_ fetcher: Fetcher, trust: Trust = Trust()) -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeSource: { _ in SampleInboxSource() },
            makeTrust: { _ in trust },
            makeCommentsFetcher: { _ in fetcher }
        )
    }

    @Test func marksInstructionsAfterLastReplyAsUnprocessed() async {
        let comments = [
            IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で"),
            IssueComment(id: 2, author: "mrs1669", body: "\(DecisionLogMarker.reply)\n対応しました"),
            IssueComment(id: 3, author: "someone", body: "#4 は別案 2 で"),
            // 書き込み権限を持つ共同開発者は、そのリポジトリで信用する
            IssueComment(id: 4, author: "partner", body: "#4 の「文言」について:\n短くしたい")
        ]
        let trust = Trust()
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(comments: comments), trust: trust))

        #expect(model.state == .loaded)
        #expect(model.rows.map(\.entry.kind) == [.instruction(isProcessed: true), .reply, .untrusted, .instruction(isProcessed: false)])
        #expect(model.unprocessedCount == 1)
        #expect(trust.asked.withLock { $0 } == ["o/r"])
    }

    @Test func hidesMarkerFromRenderedBody() async {
        let comments = [IssueComment(id: 1, author: "mrs1669", body: "\(DecisionLogMarker.reply)\n対応しました")]
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(comments: comments)))

        #expect(model.rows.first?.renderedBody == RenderedBody(body: "対応しました"))
    }

    @Test func keepsPreviousRowsOnFailure() async {
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(comments: [IssueComment(id: 1, author: "mrs1669", body: "OK")])))
        await model.load(using: Self.inbox(Fetcher(failure: .http(status: 500, message: nil))))

        #expect(model.rows.count == 1)
        guard case let .failed(message) = model.state else {
            Issue.record("失敗が表示されない")
            return
        }
        #expect(!message.contains("github_pat_saved"))
    }
}
