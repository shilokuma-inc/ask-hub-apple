import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - ask への回答（回答待ちのタスクだけが残る epic）

extension OrchestratorTests {
    @Test func resumesEpicWithOnlyWaitingTasksAndRewritesFinalPullRequest() async throws {
        let github = FakeGitHub([.success([])])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true, body: "- 回答待ちの PR: #34"))
        let runtime = FakeRuntime()
        // 回答待ちのタスクしか残っていない epic（最終 PR のマージ待ち）
        runtime.setEpic(EpicSnapshot(
            branch: "epic/mvp",
            goal: "- [x] 【FEAT】A\n- [ ] 【FEAT】B  ※回答待ち（PR #34 / ask id 1）",
            state: "## 最終 PR に載せる内容\n- 回答待ちの PR: #34\n",
            loopPrepared: true
        ))
        let inbox = FakeInbox()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, inbox: inbox)
        // 最終 PR は前のポーリングで扱い済み
        try await orchestrator.pollOnce()
        #expect(runtime.launched.isEmpty)

        inbox.set([Self.pullRequest()], threads: ["PR_34": [Self.ask("C_1", replies: ["mrs1669"])]])
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        // 回答待ちのタスクしか残っていなくても起動スクリプトが起動するよう、ask への回答による再開だと伝える
        #expect(runtime.launchEnvironments.first?["ASKHUB_RESUME_REASON"] == "answer")
        #expect(github.removedNeedsAnswer == ["PR_34"])

        // ループが回答を処理して再び完了したら、最終 PR の本文を書き直す
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies.isEmpty)
        runtime.setEpic(EpicSnapshot(
            branch: "epic/mvp",
            goal: "- [x] 【FEAT】A\n- [x] 【FEAT】B",
            state: "## 最終 PR に載せる内容\n- #34 をマージした\n",
            loopPrepared: true
        ))
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies == ["#61: - #34 をマージした" + GitHubOrchestrator.epicFinalFooter])
        #expect(runtime.launched.count == 1)
    }
}
