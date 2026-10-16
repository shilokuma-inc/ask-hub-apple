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

    /// 取得の回数を数え、最初の取得だけ少し待つ（取得中にもう一度呼ばれたときの確認用）
    private final class SlowFetcher: DecisionLogCommentsFetching {
        let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

        func comments(of issue: InboxIssue) async throws -> [IssueComment] {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if call == 1 {
                try await Task.sleep(for: .milliseconds(200))
            }
            return [IssueComment(id: call, author: "mrs1669", body: "#3 は別案 1 で")]
        }
    }

    /// 打ち切られたことにする
    private struct CancelledFetcher: DecisionLogCommentsFetching {
        func comments(of issue: InboxIssue) async throws -> [IssueComment] {
            throw CancellationError()
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

    private static func inbox(
        _ fetcher: any DecisionLogCommentsFetching,
        trust: Trust = Trust(),
        tokenStore: InMemoryTokenStore = InMemoryTokenStore(token: "github_pat_saved")
    ) -> InboxModel {
        InboxModel(
            tokenStore: tokenStore,
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

    @Test func treatsCloseCommentAsMarker() async {
        let comments = [
            IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で"),
            IssueComment(id: 2, author: "mrs1669", body: "\(DecisionLogMarker.close)\n閉じます")
        ]
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(comments: comments)))

        #expect(model.rows.map(\.entry.kind) == [.instruction(isProcessed: true), .close])
        #expect(model.unprocessedCount == 0)
    }

    @Test func reportsMissingToken() async {
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(), tokenStore: InMemoryTokenStore(token: nil)))

        #expect(model.state == .failed("トークンが未設定です。設定で保存してください"))
    }

    @Test func cancellationIsNotShownAsFailure() async {
        // 画面から外れて打ち切られても失敗とは出さず、次に表示したときに取り直せるようにする
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(CancelledFetcher()))

        #expect(model.state == .idle)
    }

    @Test func reloadsAfterLoadRequestedWhileLoading() async {
        // 取得中に指示を投稿しても、投稿後の取り直しを捨てない
        let fetcher = SlowFetcher()
        let inbox = Self.inbox(fetcher)
        let model = DecisionLogHistoryModel(issue: Self.issue)
        async let first: Void = model.load(using: inbox)
        while !model.isLoading {
            await Task.yield()
        }
        await model.load(using: inbox)
        await first

        #expect(fetcher.calls.withLock { $0 } == 2)
        #expect(model.rows.map(\.id) == [2])
        #expect(model.state == .loaded)
    }

    @Test func permissionErrorExplainsReadAccess() async {
        let model = DecisionLogHistoryModel(issue: Self.issue)
        await model.load(using: Self.inbox(Fetcher(failure: .http(status: 404, message: "Not Found"))))

        guard case let .failed(message) = model.state else {
            Issue.record("失敗が表示されない")
            return
        }
        #expect(message.contains("読み取り権限"))
    }
}
