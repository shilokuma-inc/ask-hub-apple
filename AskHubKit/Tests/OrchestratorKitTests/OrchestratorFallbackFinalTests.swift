import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - GitHub の情報から作る最終 PR

extension OrchestratorTests {
    private static let materials = EpicMaterials(
        mergedPullRequests: [.init(number: 333, title: "目印を定める"), .init(number: 335, title: "目印を書く")],
        openPullRequests: [],
        decisionLogs: [.init(number: 336, title: "【CHORE】epic/verify-tab-ui の仮決め一覧")],
        verifyIssues: [.init(number: 347, title: "【CHORE】実機確認: Issue を閉じる")]
    )

    @Test func createsFinalPullRequestFromGitHubWhenManualLoopCompletes() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let report = LoopStatusReport(state: .completed, writer: .manual, epic: "epic/verify-tab-ui", discussion: 331, checkedAt: checkedAt)
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 229, author: "mrs1669", isOpen: true, updatedAt: checkedAt, body: report.issueBody)
        ])
        github.setEpicMaterials(Self.materials, for: "epic/verify-tab-ui")
        let clock = TestClock(checkedAt.addingTimeInterval(60))
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime(), now: { clock.now })

        // 完了から 30 分は、担当者が askhub-manual.sh final で作るのを待つ
        try await orchestrator.pollOnce()
        #expect(github.createdEpicPullRequests.isEmpty)

        clock.now = checkedAt.addingTimeInterval(LoopStatusReport.freshness)
        try await orchestrator.pollOnce()
        // 同じ epic では 1 回だけ作る
        clock.now = clock.now.addingTimeInterval(Orchestrator.fallbackFinalCheckInterval)
        try await orchestrator.pollOnce()

        let created = try #require(github.createdEpicPullRequests.first)
        #expect(github.createdEpicPullRequests.count == 1)
        #expect(created.hasPrefix("shilokuma-inc/ask-hub-apple epic/verify-tab-ui: ゴール元: Discussion #331\n<!-- ask-hub:discussion 331 -->"))
        #expect(created.contains("- #333 目印を定める"))
        #expect(created.contains("- #336 【CHORE】epic/verify-tab-ui の仮決め一覧"))
        #expect(created.contains("手動ループ（`manual-loop`）で回した epic"))
        #expect(github.labeledPullRequests == [100])
    }

    @Test func createsFinalPullRequestFromGitHubWhenSummaryIsMissing() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicMaterials(Self.materials, for: "epic/mvp")
        let runtime = FakeRuntime()
        // タスクは終わっているが、state の「最終 PR に載せる内容」が無い
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: "## メモ\n", discussion: 12, loopPrepared: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        let created = try #require(github.createdEpicPullRequests.first)
        #expect(created.contains("ゴール元: Discussion #12"))
        #expect(created.contains("ループが state の「最終 PR に載せる内容」を書かずに終わった"))
    }

    @Test func doesNotCreateFinalPullRequestForStalledLoopOrEpicWithoutChildren() async throws {
        // 異常終了したループは、再開して内容を書かせる
        let stalledGitHub = FakeGitHub([.success([])])
        stalledGitHub.setEpicMaterials(Self.materials, for: "epic/mvp")
        let stalled = FakeRuntime()
        stalled.set(LoopStatus(stateFileExists: false, processAlive: false, stalled: true))
        stalled.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: "## メモ\n", discussion: 12, loopPrepared: true))
        try await makeOrchestrator(github: stalledGitHub, runtime: stalled).pollOnce()
        #expect(stalledGitHub.createdEpicPullRequests.isEmpty)

        // epic にマージされた子 PR が無ければ作らない
        let emptyGitHub = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: "## メモ\n", discussion: 12, loopPrepared: true))
        try await makeOrchestrator(github: emptyGitHub, runtime: runtime).pollOnce()
        #expect(emptyGitHub.createdEpicPullRequests.isEmpty)
        #expect(logs.recorded.contains { $0.contains("epic にマージされた子 PR が無いので最終 PR を作りません") })
    }
}
