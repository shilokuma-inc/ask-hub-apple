import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - 最終 PR への指示

extension OrchestratorTests {
    private static let finalPullRequest = EpicFinalPullRequest(
        repository: "shilokuma-inc/ask-hub-apple",
        number: 61,
        headBranch: "epic/mvp",
        author: "mrs1669"
    )

    private static let finalInstruction = IssueComment(
        id: 101,
        author: "mrs1669",
        body: "https://github.com/shilokuma-inc/ask-hub-apple/pull/61#discussion_r555 を直して"
    )

    @Test func resumesLoopOnceForFinalPullRequestInstruction() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        // タスクがすべて完了していても起動スクリプトがループを起動するよう、最終 PR への指示による再開だと伝える
        #expect(runtime.launchEnvironments.first?["ASKHUB_RESUME_REASON"] == "final-pr")
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#61 の最終 PR に指示が付いたので、ループを再開しました"))

        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#61 の最終 PR の指示で再開したループの開始を確かめました"))

        // ループが返信せずに止まっても、同じコメントでは再開しない
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
    }

    @Test func rewritesFinalPullRequestBodyAfterLoopResumedByFinalPullRequestInstruction() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true, body: "- 古いまとめ"))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FIX】#discussion_r555 の指摘", state: "## 最終 PR に載せる内容\n- 新しいまとめ\n"))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(github.updatedPullRequestBodies.isEmpty)
        runtime.set(.idle)
        try await orchestrator.pollOnce()

        #expect(github.updatedPullRequestBodies == ["#61: - 新しいまとめ" + GitHubOrchestrator.epicFinalFooter])
    }

    @Test func doesNotResumeForCommentsThatAreNotUnprocessedInstructions() async throws {
        let reply = IssueComment(id: 102, author: "mrs1669", body: "\(FinalPullRequestMarker.reply)\n直しました")
        let orchestratorComment = IssueComment(id: 103, author: "mrs1669", body: "\(FinalPullRequestMarker.orchestrator)\ndevelop を取り込みました")
        let legacy = IssueComment(id: 104, author: "mrs1669", body: "develop を取り込みました。CI が通ってからマージしてください。（askhub-orchestrator）")
        let review = IssueComment(id: 105, author: "mrs1669", body: "@coderabbitai review")
        let codeRabbit = IssueComment(id: 106, author: "coderabbitai[bot]", body: "Actionable comments posted: 1")
        let untrusted = IssueComment(id: 107, author: "someone", body: "#discussion_r555 を直して")
        for comments in [
            [],
            [Self.finalInstruction, reply],
            [orchestratorComment, legacy, review, codeRabbit, untrusted]
        ] {
            let github = FakeGitHub([.success([])])
            github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: comments])
            let runtime = FakeRuntime()
            try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

            #expect(runtime.launched.isEmpty)
        }
    }

    @Test func ignoresFinalPullRequestCreatedByUntrustedAuthor() async throws {
        let github = FakeGitHub([.success([])])
        let forged = EpicFinalPullRequest(repository: "shilokuma-inc/ask-hub-apple", number: 62, headBranch: "epic/mvp", author: "someone")
        github.setEpicFinalPullRequests([forged], comments: [62: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.isEmpty)
    }

    @Test func doesNotResumeFinalPullRequestWhenControlWorktreeMovedToAnotherEpic() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/next", goal: nil, state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        // 制御用 worktree の epic（epic/next）の最終 PR がまだ無いので、作り終えるまで待つ（処理済みにはしない）
        #expect(runtime.launched.isEmpty)
        let message = "shilokuma-inc/ask-hub-apple#61 の最終 PR に指示が付きましたが、制御用 worktree の epic/next の最終 PR がまだ無いので、作り終えるまで待ちます"
        #expect(logs.recorded.filter { $0 == message }.count == 1)

        // 最終 PR を作り終えたら、epic/mvp を戻して再開する
        github.addExistingPullRequest(head: "epic/next", ExistingPullRequest(number: 70, isOpen: true))
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        #expect(runtime.launchEnvironments.first?["ASKHUB_RESTORE_EPIC"] == "epic/mvp")
        #expect(runtime.launchEnvironments.first?["ASKHUB_RESUME_REASON"] == "final-pr")
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#61 の最終 PR に指示が付いたので、制御用 worktree を epic/mvp に戻してループを再開しました"))
    }

    @Test func retriesRestoreWithSameEpicUntilLoopStarts() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        github.addExistingPullRequest(head: "epic/next", ExistingPullRequest(number: 70, isOpen: false, isMerged: true))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/next", goal: "- [x] 【FEAT】完了済み", state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 起動スクリプトが戻せずに終わった（退避が無いなど）。同じ epic を戻すよう、上限まで呼び直す
        for attempt in 1...Orchestrator.maxDecisionResumeAttempts {
            try await orchestrator.pollOnce()
            #expect(runtime.launched.count == attempt)
            runtime.set(Self.exitedWithoutStarting)
        }
        #expect(runtime.launchEnvironments.allSatisfy { $0["ASKHUB_RESTORE_EPIC"] == "epic/mvp" })
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == Orchestrator.maxDecisionResumeAttempts)
    }

    @Test func doesNotRestoreManualLoopEpicOrOverManualLoop() async throws {
        // 指示の最終 PR が手動ループの epic（ゴール元が手動ループの Discussion）なら、担当者が再開する
        let manualFinal = EpicFinalPullRequest(
            repository: "shilokuma-inc/ask-hub-apple",
            number: 61,
            headBranch: "epic/mvp",
            author: "mrs1669",
            goalDiscussion: 331
        )
        let github = FakeGitHub([.success([])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        github.setEpicFinalPullRequests([manualFinal], comments: [61: [Self.finalInstruction]])
        github.addExistingPullRequest(head: "epic/next", ExistingPullRequest(number: 70, isOpen: true))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/next", goal: nil, state: nil, discussion: 12))
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()
        #expect(runtime.launched.isEmpty)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#61 の最終 PR に指示が付きましたが、epic/mvp は手動ループの epic なので再開しません（担当者が再開します）"))

        // 制御用 worktree を手動ループ（kit 1.3 まで）が使っていれば、終わるまで待つ
        let other = FakeGitHub([.success([])])
        other.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        other.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        other.addExistingPullRequest(head: "epic/manual", ExistingPullRequest(number: 70, isOpen: true))
        let manualRuntime = FakeRuntime()
        manualRuntime.setEpic(EpicSnapshot(branch: "epic/manual", goal: nil, state: nil, discussion: 331))
        try await makeOrchestrator(github: other, runtime: manualRuntime).pollOnce()
        #expect(manualRuntime.launched.isEmpty)
        #expect(logs.recorded.contains { $0.contains("制御用 worktree を手動ループ（epic/manual）が使っているので、終わるまで待ちます") })
    }

    @Test func resumesOnlyOnceWhenDecisionLogAndFinalPullRequestBothHaveInstructions() async throws {
        let github = FakeGitHub([.success([])])
        let decisionLog = DecisionLogIssue(repository: "shilokuma-inc/ask-hub-apple", number: 20, title: "【CHORE】epic/mvp の仮決め一覧", body: "")
        github.setDecisionLogs([decisionLog], comments: [20: [IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で")]])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        #expect(runtime.launchEnvironments.first?["ASKHUB_RESUME_REASON"] == "decision-log")

        // 再開したループが始まって止まった後は、残っている最終 PR への指示で再開する（ループは周回の最初に両方を読む）
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 2)
        #expect(runtime.launchEnvironments.last?["ASKHUB_RESUME_REASON"] == "final-pr")
    }

    @Test func doesNotResumeManualLoopEpicFromFinalPullRequest() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        // kit 1.3 までの手動ループは、この PC の制御用 worktree を使うことがある（ゴール元の記録が無い・手動ループの Discussion）
        for discussion: Int? in [nil, 331] {
            runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】完了済み", state: nil, discussion: discussion))
            let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
            try await orchestrator.pollOnce()
            try await orchestrator.pollOnce()
        }

        #expect(runtime.launched.isEmpty)
        let message = "shilokuma-inc/ask-hub-apple#61 の最終 PR に指示が付きましたが、epic/mvp は手動ループの epic なので再開しません（担当者が再開します）"
        #expect(logs.recorded.filter { $0 == message }.count == 2)
    }

    @Test func doesNotListFinalPullRequestsWhileLoopIsRunning() async throws {
        let github = FakeGitHub([.success([])])
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        runtime.set(Self.started)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.epicFinalListings == 0)

        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(github.epicFinalListings == 1)
        #expect(runtime.launched.count == 1)

        // 開始を確かめる間は、ループが動いていても一覧を取る
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(github.epicFinalListings == 2)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#61 の最終 PR の指示で再開したループの開始を確かめました"))
    }

    @Test func postponesResumeWhileManualLoopsCannotBeFetched() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        github.setManualLoopsFail(true)
        github.setEpicFinalPullRequests([Self.finalPullRequest], comments: [61: [Self.finalInstruction]])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】完了済み", state: nil, discussion: 331))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 手動ループかを決められない回は再開せず、処理済みにもしない
        try await orchestrator.pollOnce()
        #expect(runtime.launched.isEmpty)

        // 取得できたら、手動ループの epic なので再開しない
        github.setManualLoopsFail(false)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.isEmpty)
        #expect(logs.recorded.contains { $0.contains("epic/mvp は手動ループの epic なので再開しません") })
    }

    @Test func doesNotResumeManualLoopEpicFromDecisionLog() async throws {
        let github = FakeGitHub([.success([])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 331, author: "mrs1669")])
        let decisionLog = DecisionLogIssue(repository: "shilokuma-inc/ask-hub-apple", number: 20, title: "【CHORE】epic/mvp の仮決め一覧", body: "")
        github.setDecisionLogs([decisionLog], comments: [20: [IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で")]])
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 61, isOpen: true))
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】完了済み", state: nil, discussion: 331))

        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.isEmpty)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#20 の仮決め一覧に指示が付きましたが、epic/mvp は手動ループの epic なので再開しません（担当者が再開します）"))
    }
}
