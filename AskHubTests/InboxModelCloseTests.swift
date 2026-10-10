@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 実機確認の Issue を確認済みとして閉じる（Discussion #331 の Q5）
@MainActor
struct InboxModelCloseTests {
    /// 実機確認の Issue を 2 件返す取得元（閉じても、検索に反映されるまでは返し続ける）
    private struct IssuesSource: InboxSource {
        func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
            []
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            []
        }

        func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
            [Self.issue("I_1"), Self.issue("I_2")]
        }

        static func issue(_ id: String) -> InboxIssue {
            InboxIssue(
                id: id,
                kind: .needsVerify,
                repository: "o/r",
                number: 1,
                title: "【CHORE】実機確認: \(id)",
                url: URL(string: "https://github.com/o/r/issues/1")!,
                author: "mrs1669",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
    }

    /// 閉じた Issue を記録する。`failure` を渡すと失敗する
    private final class RecordingCloser: IssueClosing {
        let closed = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let failure: GitHubError?

        init(failure: GitHubError? = nil) {
            self.failure = failure
        }

        func closeAsVerified(_ issue: InboxIssue) async throws {
            if let failure {
                throw failure
            }
            closed.withLock { $0.append(issue.id) }
        }
    }

    private static func model(
        closer: RecordingCloser,
        tokenStore: InMemoryTokenStore = InMemoryTokenStore(token: "github_pat_saved")
    ) -> InboxModel {
        InboxModel(
            tokenStore: tokenStore,
            makeSource: { _ in IssuesSource() },
            makeCloser: { _ in closer },
            makeTrust: { _ in TrustedAuthors.default }
        )
    }

    @Test func closedIssueStaysOutOfListAfterRefresh() async throws {
        let closer = RecordingCloser()
        let model = Self.model(closer: closer)
        await model.refresh()

        try await model.closeAsVerified(IssuesSource.issue("I_1"))

        #expect(closer.closed.withLock { $0 } == ["I_1"])
        // 検索に反映されるまで取得元は閉じた Issue も返すが、一覧には戻さない
        #expect(model.issues.map(\.id) == ["I_2"])
        await model.refresh()
        #expect(model.issues.map(\.id) == ["I_2"])
    }

    @Test func failedCloseKeepsIssueInList() async {
        let forbidden = GitHubError.http(status: 403, message: "Resource not accessible by personal access token")
        let closer = RecordingCloser(failure: forbidden)
        let model = Self.model(closer: closer)
        await model.refresh()

        await #expect(throws: forbidden) {
            try await model.closeAsVerified(IssuesSource.issue("I_1"))
        }
        #expect(Set(model.issues.map(\.id)) == ["I_1", "I_2"])
    }

    @Test func closeWithoutTokenFails() async {
        let closer = RecordingCloser()
        let model = Self.model(closer: closer, tokenStore: InMemoryTokenStore())

        await #expect(throws: InboxModel.MissingTokenError.self) {
            try await model.closeAsVerified(IssuesSource.issue("I_1"))
        }
        #expect(closer.closed.withLock { $0 }.isEmpty)
    }

    /// 閉じるのを、テストが開けるまで止めておく
    private final class GatedCloser: IssueClosing {
        private let gate = OSAllocatedUnfairLock<(opened: Bool, waiters: [CheckedContinuation<Void, Never>])>(initialState: (false, []))

        var isWaiting: Bool {
            gate.withLock { !$0.waiters.isEmpty }
        }

        func open() {
            let waiters = gate.withLock { state in
                state.opened = true
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }

        func closeAsVerified(_ issue: InboxIssue) async throws {
            await withCheckedContinuation { continuation in
                let opened = gate.withLock { state in
                    if !state.opened {
                        state.waiters.append(continuation)
                    }
                    return state.opened
                }
                if opened {
                    continuation.resume()
                }
            }
        }
    }

    @Test func closeFinishedAfterTokenChangeKeepsNewTokensList() async throws {
        let store = InMemoryTokenStore(token: "github_pat_old")
        let closer = GatedCloser()
        let model = InboxModel(
            tokenStore: store,
            makeSource: { _ in IssuesSource() },
            makeCloser: { _ in closer },
            makeTrust: { _ in TrustedAuthors.default }
        )
        await model.refresh()

        let closing = Task { try await model.closeAsVerified(IssuesSource.issue("I_1")) }
        while !closer.isWaiting {
            await Task.yield()
        }
        // 閉じるのを待つ間に、設定で別のトークンを保存して取り直した
        try store.save("github_pat_new")
        await model.refresh()
        closer.open()
        try await closing.value

        // 古いトークンで閉じた結果で、新しいトークンの一覧を書き換えない
        #expect(Set(model.issues.map(\.id)) == ["I_1", "I_2"])
    }

    @Test func closeMessageExplainsMissingPermission() {
        let expected = "閉じられませんでした。トークンに、このリポジトリの Issues の書き込み権限（Read and write）があるか確かめてください"
        #expect(InboxModel.closeMessage(for: GitHubError.http(status: 403, message: "Resource not accessible")) == expected)
        #expect(InboxModel.closeMessage(for: GitHubError.http(status: 404, message: "Not Found")) == expected)
        // それ以外は取得・投稿と同じ説明
        #expect(InboxModel.closeMessage(for: GitHubError.http(status: 401, message: nil)) == "トークンが無効です。設定でトークンを保存し直してください")
    }
}
