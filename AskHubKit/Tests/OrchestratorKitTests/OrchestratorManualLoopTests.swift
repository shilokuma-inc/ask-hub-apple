import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// 手で回す Discussion（manual-loop）の扱い
extension OrchestratorTests {
    @Test func removesOnlyNeedsAnswerFromManualLoopDiscussion() async throws {
        let github = FakeGitHub([.success([])])
        let inbox = FakeInbox()
        func discussion(_ number: Int, author: String) -> InboxSubject {
            InboxSubject(
                kind: .discussion,
                nodeID: "D_\(number)",
                repository: "shilokuma-inc/ask-hub-apple",
                number: number,
                title: "依頼",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/\(number)")!,
                author: author,
                labels: ["needs-answer", "manual-loop"]
            )
        }
        inbox.set(
            [discussion(273, author: "mrs1669"), discussion(274, author: "someone")],
            threads: [
                "D_273": [Self.ask("C_1", replies: ["mrs1669"])],
                "D_274": [Self.ask("C_2", replies: ["mrs1669"])]
            ]
        )
        try await makeOrchestrator(github: github, runtime: FakeRuntime(), inbox: inbox).pollOnce()

        // 手で回す Discussion には ready-for-loop を付けず、needs-answer だけを外す。
        // 信用外の author の Discussion に付いた manual-loop は無視する
        #expect(github.addedReady == ["D_274"])
        #expect(Set(github.removedNeedsAnswer) == ["D_273", "D_274"])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#273 は manual-loop（手で回す）なので、ready-for-loop は付けません"))
    }
}

// 手動ループ（担当者の Mac で回すループ）があるリポジトリの扱い
extension OrchestratorTests {
    static let manualLoop = ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 273, author: "mrs1669")

    @Test func doesNotResumeLoopOfRepositoryWithManualLoop() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([Self.manualLoop])
        let runtime = FakeRuntime()
        let inbox = FakeInbox()
        inbox.set([Self.pullRequest()], threads: ["PR_34": [Self.ask("C_3", replies: ["mrs1669"])]])

        try await makeOrchestrator(github: github, runtime: runtime, inbox: inbox).pollOnce()

        // ループは担当者の Mac で動いているので、この PC のループは再開しない（needs-answer は外す）
        #expect(runtime.launched.isEmpty)
        #expect(github.removedNeedsAnswer == ["PR_34"])
    }

    @Test func keepsStatusOfManualLoopEvenAfterItGoesStale() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([Self.manualLoop])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let manual = LoopStatusReport(state: .running, writer: .manual, discussion: 273, checkedAt: start, runner: "partner")
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 101, author: "mrs1669", isOpen: true, updatedAt: start, body: manual.issueBody)
        ])
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime()) { clock.withLock { $0 } }

        // 手動ループの Discussion が開いている間は、確認時刻が古くなっても上書きしない（担当者の情報を残す）
        clock.withLock { $0 = start.addingTimeInterval(LoopStatusReport.freshness + 60) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) }?.runner == "partner")

        // 手動ループが終わって Discussion が閉じたら、今までどおり書き直す
        github.setManualLoops([])
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
    }
}
