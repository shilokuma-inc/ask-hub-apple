import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - 仮決め一覧（decision-log）

extension OrchestratorTests {
    private static func decisionLog(body: String = "- [x] #3 色 → 採用: 青") -> DecisionLogIssue {
        DecisionLogIssue(repository: "shilokuma-inc/ask-hub-apple", number: 20, title: "【CHORE】epic/mvp の仮決め一覧", body: body)
    }

    private static let instruction = IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で")

    @Test func closesDecisionLogWhenFinalPullRequestIsMerged() async throws {
        let github = FakeGitHub([.success([])])
        github.setDecisionLogs([Self.decisionLog(body: "- [x] #3 色 → 採用: 青\n- [ ] #4 文言 → 採用: 保存")])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: false, isMerged: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())

        try await orchestrator.pollOnce()

        #expect(github.closedDecisionLogs == [20])
        #expect(github.decisionComments.count == 1)
        #expect(github.decisionComments.first?.contains("既定値のまま確定しました。\n- #4 文言 → 採用: 保存") == true)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple の最終 PR #61 がマージ済みなので、仮決め一覧 #20 を閉じました"))
    }

    @Test func doesNotCommentTwiceWhenClosingFails() async throws {
        let github = FakeGitHub([.success([])])
        github.setDecisionLogs([Self.decisionLog()])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: false, isMerged: true))
        github.setDecisionCloseFails(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())

        try await orchestrator.pollOnce()
        github.setDecisionCloseFails(false)
        try await orchestrator.pollOnce()

        // 前回のコメント（目印付き）が残っているので、クローズだけやり直す
        #expect(github.decisionComments.count == 1)
        #expect(github.closedDecisionLogs == [20])
    }

    @Test func keepsDecisionLogOpenUntilFinalPullRequestIsMerged() async throws {
        for existing: ExistingPullRequest? in [
            nil,
            ExistingPullRequest(number: 61, isOpen: true),
            // マージせずに閉じた PR は epic を取り込んでいないので、人の判断に任せる
            ExistingPullRequest(number: 61, isOpen: false, isMerged: false)
        ] {
            let github = FakeGitHub([.success([])])
            github.setDecisionLogs([Self.decisionLog()])
            if let existing {
                github.addExistingPullRequest(head: "epic/mvp", existing)
            }
            try await makeOrchestrator(github: github, runtime: FakeRuntime()).pollOnce()

            #expect(github.closedDecisionLogs.isEmpty)
            #expect(github.decisionComments.isEmpty)
        }
    }

    @Test func resumesLoopOnceForInstructionWhileWaitingForMerge() async throws {
        let github = FakeGitHub([.success([])])
        github.setDecisionLogs([Self.decisionLog()], comments: [20: [Self.instruction]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#20 の仮決め一覧に指示が付いたので、ループを再開しました"))

        // ループが返信せずに止まっても、同じコメントでは再開しない
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
    }

    @Test func rewritesFinalPullRequestBodyAfterResumedLoopCompletes() async throws {
        let github = FakeGitHub([.success([])])
        github.setDecisionLogs([Self.decisionLog()], comments: [20: [Self.instruction]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true, body: "- 古いまとめ"))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(
            branch: "epic/mvp",
            goal: "- [x] 【FIX】#3 を別案 1 に",
            state: "## 最終 PR に載せる内容\n- 新しいまとめ\n",
            discussion: 12
        ))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies.isEmpty)

        // 再開したループが promise を出して止まった
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies == [
            "#61: ゴール元: Discussion #12\n<!-- ask-hub:discussion 12 -->\n\n- 新しいまとめ" + GitHubOrchestrator.epicFinalFooter
        ])

        // 書き直しは 1 回だけ
        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies.count == 1)
    }

    @Test func doesNotResumeWithoutUnprocessedInstruction() async throws {
        let reply = IssueComment(id: 2, author: "mrs1669", body: "\(DecisionLog.replyMarker)\n#3 を変更しました")
        let untrusted = IssueComment(id: 3, author: "someone", body: "#3 は別案 2 で")
        for comments in [[], [Self.instruction, reply], [reply, untrusted]] {
            let github = FakeGitHub([.success([])])
            github.setDecisionLogs([Self.decisionLog()], comments: [20: comments])
            github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
            let runtime = FakeRuntime()
            try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

            #expect(runtime.launched.isEmpty)
        }
    }

    @Test func leavesRunningOrStalledLoopToItself() async throws {
        for status in [
            LoopStatus(stateFileExists: true, processAlive: true),
            LoopStatus(stateFileExists: nil, processAlive: false)
        ] {
            let github = FakeGitHub([.success([])])
            github.setDecisionLogs([Self.decisionLog()], comments: [20: [Self.instruction]])
            github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
            let runtime = FakeRuntime()
            runtime.set(status)
            try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

            #expect(runtime.launched.isEmpty)
        }
    }

    @Test func doesNotResumeWhenControlWorktreeMovedToAnotherEpic() async throws {
        let github = FakeGitHub([.success([])])
        github.setDecisionLogs([Self.decisionLog()], comments: [20: [Self.instruction]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/next", goal: nil, state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.launched.isEmpty)
        let message = "shilokuma-inc/ask-hub-apple#20 の仮決め一覧に指示が付きましたが、制御用 worktree が epic/mvp ではないのでループを再開できません"
        #expect(logs.recorded.filter { $0 == message }.count == 1)
    }
}
