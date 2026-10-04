import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - epic の最終 PR

extension OrchestratorTests {
    private static let completedEpic = EpicSnapshot(
        branch: "epic/mvp",
        goal: "- [x] 【FEAT】A\n- [ ] 【FEAT】B  ※回答待ち（PR #3 / ask id 1）",
        state: "## 最終 PR に載せる内容\n- 回答待ち: #3\n\n## メモ\n"
    )

    @Test func createsEpicFinalPullRequestOnceWhenEpicCompletes() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(Self.completedEpic)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(github.createdEpicPullRequests == ["shilokuma-inc/ask-hub-apple epic/mvp: - 回答待ち: #3"])
        #expect(github.labeledPullRequests == [100])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple の epic/mvp が完了したので、最終 PR #100 を作りました"))
    }

    @Test func putsGoalDiscussionMarkerAtTopOfEpicFinalPullRequest() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        let epic = Self.completedEpic
        runtime.setEpic(EpicSnapshot(branch: epic.branch, goal: epic.goal, state: epic.state, discussion: 12))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(github.createdEpicPullRequests == [
            "shilokuma-inc/ask-hub-apple epic/mvp: ゴール元: Discussion #12\n<!-- ask-hub:discussion 12 -->\n\n- 回答待ち: #3"
        ])
    }

    @Test func addsGoalDiscussionMarkerToExistingOpenPullRequestWithoutIt() async throws {
        let epic = Self.completedEpic
        let withDiscussion = EpicSnapshot(branch: epic.branch, goal: epic.goal, state: epic.state, discussion: 12)

        // 目印の無い open な PR には足してからラベルを付ける
        let github = FakeGitHub([.success([])])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 9, isOpen: true, body: "- まとめ"))
        let runtime = FakeRuntime()
        runtime.setEpic(withDiscussion)
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()
        #expect(github.updatedPullRequestBodies == ["#9: ゴール元: Discussion #12\n<!-- ask-hub:discussion 12 -->\n\n- まとめ"])
        #expect(github.labeledPullRequests == [9])
        #expect(github.createdEpicPullRequests.isEmpty)

        // 既に目印がある PR・閉じた PR は書き換えない
        for existing in [
            ExistingPullRequest(number: 9, isOpen: true, body: "ゴール元: Discussion #12\n<!-- ask-hub:discussion 12 -->\n"),
            ExistingPullRequest(number: 7, isOpen: false, body: "- まとめ")
        ] {
            let other = FakeGitHub([.success([])])
            other.addExistingPullRequest(head: "epic/mvp", existing)
            let otherRuntime = FakeRuntime()
            otherRuntime.setEpic(withDiscussion)
            try await makeOrchestrator(github: other, runtime: otherRuntime).pollOnce()
            #expect(other.updatedPullRequestBodies.isEmpty)
        }
    }

    @Test func relabelsCreatedPullRequestWhenLabelingFailed() async throws {
        let github = FakeGitHub([.success([])])
        github.setLabelFails(true)
        let runtime = FakeRuntime()
        runtime.setEpic(Self.completedEpic)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.labeledPullRequests.isEmpty)

        // 次のポーリングでは PR を作り直さず、既存の PR にラベルを付け直す
        github.setLabelFails(false)
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()
        #expect(github.createdEpicPullRequests.count == 1)
        #expect(github.labeledPullRequests == [100])
    }

    @Test func doesNotCreateEpicFinalWhenPullRequestExistsOrLoopIsActive() async throws {
        let github = FakeGitHub([.success([])])
        // 人が閉じた PR にはラベルを付けず、作り直しもしない
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 7, isOpen: false))
        let runtime = FakeRuntime()
        runtime.setEpic(Self.completedEpic)
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()
        #expect(github.createdEpicPullRequests.isEmpty)
        #expect(github.labeledPullRequests.isEmpty)

        let otherGitHub = FakeGitHub([.success([])])
        let running = FakeRuntime()
        running.setEpic(Self.completedEpic)
        running.set(LoopStatus(stateFileExists: true, processAlive: true))
        try await makeOrchestrator(github: otherGitHub, runtime: running).pollOnce()
        #expect(otherGitHub.createdEpicPullRequests.isEmpty)
    }

    @Test func doesNotCreateEpicFinalRightAfterLaunchingLoopInSamePoll() async throws {
        // ready-for-loop で起動したリポジトリは、同じ周回では動いているとみなす
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.setEpic(Self.completedEpic)
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.count == 1)
        #expect(github.createdEpicPullRequests.isEmpty)
    }
}
