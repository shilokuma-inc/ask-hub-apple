@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct InboxModelTests {
    /// 失敗させるかを差し替えられる取得元
    private final class StubSource: InboxSource {
        private let failure: GitHubError?

        init(failure: GitHubError? = nil) {
            self.failure = failure
        }

        func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
            if let failure {
                throw failure
            }
            return [Self.subject]
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            [
                QuestionThread(
                    comment: InboxComment(
                        nodeID: "C_1",
                        databaseID: 1,
                        author: "mrs1669",
                        body: "<!-- ask-hub:question id=\"d1-q1\" -->\n質問",
                        url: Self.subject.url,
                        createdAt: Date(timeIntervalSince1970: 0)
                    ),
                    replyAuthors: []
                )
            ]
        }

        func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
            [
                InboxIssue(
                    id: "I_1",
                    kind: .decisionLog,
                    repository: "o/r",
                    number: 1,
                    title: "仮決め",
                    url: Self.subject.url,
                    author: "mrs1669",
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            ]
        }

        static let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_1",
            repository: "o/r",
            number: 1,
            title: "タイトル",
            url: URL(string: "https://github.com/o/r/discussions/1")!
        )
    }

    @Test func needsTokenWithoutSavedToken() async {
        let model = InboxModel(tokenStore: InMemoryTokenStore()) { _ in StubSource() }
        await model.refresh()
        #expect(model.state == .needsToken)
        #expect(model.questions.isEmpty)
    }

    @Test func loadsQuestionsAndIssuesWithSavedToken() async {
        let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])
        let model = InboxModel(tokenStore: InMemoryTokenStore(token: "github_pat_saved")) { token in
            tokens.withLock { $0.append(token) }
            return StubSource()
        }
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.questions.map(\.id) == ["C_1"])
        #expect(model.issues.map(\.id) == ["I_1"])
        #expect(tokens.withLock { $0 } == ["github_pat_saved"])
    }

    @Test func failureKeepsPreviousResultsAndExplainsInvalidToken() async {
        let fails = OSAllocatedUnfairLock(initialState: false)
        let model = InboxModel(tokenStore: InMemoryTokenStore(token: "github_pat_saved")) { _ in
            fails.withLock { $0 } ? StubSource(failure: .http(status: 401, message: "Bad credentials")) : StubSource()
        }
        await model.refresh()
        fails.withLock { $0 = true }
        await model.refresh()

        #expect(model.state == .failed("トークンが無効です。設定でトークンを保存し直してください"))
        #expect(model.questions.map(\.id) == ["C_1"])
        #expect(!String(describing: model.state).contains("github_pat_saved"))
    }

    @Test func messageForRateLimit() {
        #expect(InboxModel.message(for: GitHubError.rateLimited(retryAfter: .seconds(90))) == "GitHub のレート制限中です。90 秒ほど待ってから更新してください")
    }

    @Test func summaryDropsMarkerImagesAndHeadingMarks() {
        let question = InboxQuestion(
            subject: StubSource.subject,
            comment: InboxComment(
                nodeID: "C_1",
                databaseID: nil,
                author: "mrs1669",
                body: """
                    <!-- ask-hub:question id="pr1-1" -->
                    ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
                    ### Q1. 単位
                    送信の上限は？
                    """,
                url: StubSource.subject.url,
                createdAt: Date()
            ),
            marker: QuestionMarker(id: "pr1-1")
        )
        #expect(question.summary == "Q1. 単位 送信の上限は？")
    }
}
