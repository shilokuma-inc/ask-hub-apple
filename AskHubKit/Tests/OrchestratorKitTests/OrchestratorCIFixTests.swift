import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR の CI の修正

extension OrchestratorTests {
    private static func failing(_ sha: String = "s1", number: Int = 50) -> FailingPullRequest {
        FailingPullRequest(repository: "shilokuma-inc/ask-hub-apple", number: number, headBranch: "epic/mvp", headSHA: sha)
    }

    /// 1 回ポーリングし、裏の修正が終わるまで待つ
    private func pollAndWait(_ orchestrator: Orchestrator) async throws {
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
    }

    @Test func fixesFailingFinalPullRequestOncePerHead() async throws {
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "直しました\nASKHUB_RESULT: fixed\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWait(orchestrator)
        // push の後に CI がまた失敗しても、同じ head では試し直さない
        try await pollAndWait(orchestrator)

        #expect(runtime.ran == [
            ["/usr/local/bin/askhub-fix-ci", "shilokuma-inc/ask-hub-apple", "/src/ask-hub-apple", "epic/mvp", "50", "s1"]
        ])
        // 試すことを先に PR に残し、結果も伝える
        #expect(github.pullRequestComments.count == 2)
        let prefix = "shilokuma-inc/ask-hub-apple#50: \(FinalPullRequestMarker.orchestrator)\n"
        #expect(github.pullRequestComments.first?.hasPrefix("\(prefix)\(CIFixTracker.attemptMarker("s1"))\n") == true)
        #expect(github.pullRequestComments.last?.hasPrefix("\(prefix)CI の失敗を直し、epic/mvp に push しました") == true)
        #expect(logs.recorded.contains { $0.contains("#50（epic/mvp の s1）の CI が失敗しているので、直させます") })
    }

    @Test func doesNotRetrySameHeadAfterRestart() async throws {
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 2, output: "ASKHUB_RESULT: unresolved 原因が分からない\n")])
        try await pollAndWait(try makeOrchestrator(github: github, runtime: runtime))

        // 再起動した（記録はメモリに無い）オーケストレーターも、PR のコメントの目印を読んで同じ head では試さない
        let restarted = try makeOrchestrator(github: github, runtime: runtime)
        try await pollAndWait(restarted)
        #expect(runtime.ran.count == 1)

        // head が変われば試す
        github.setFailingPullRequests([Self.failing("s2")])
        try await pollAndWait(restarted)
        #expect(runtime.ran.count == 2)
        #expect(runtime.ran.last?.last == "s2")
    }

    @Test func givesUpAfterMaxAttemptsAndTellsIt() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 2, output: "ASKHUB_RESULT: unresolved UI テストが通らない\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        for sha in ["s1", "s2", "s3", "s4", "s5"] {
            github.setFailingPullRequests([Self.failing(sha)])
            try await pollAndWait(orchestrator)
        }

        #expect(runtime.ran.map { $0.last } == ["s1", "s2", "s3"])
        #expect(github.pullRequestComments.contains { $0.contains("CI の失敗を自動で直せませんでした: UI テストが通らない") })
        // 3 回目も直せなかったら、そこであきらめたことを伝える（その後の head では何もしない）
        let gaveUp = github.pullRequestComments.filter { $0.contains(CIFixTracker.gaveUpMarker) }
        #expect(gaveUp.count == 1)
        #expect(gaveUp.first?.contains("3 回試したので、自動の修正はやめます") == true)
        #expect(logs.recorded.contains { $0.contains("#50 の CI の失敗を直せませんでした（あきらめます）: UI テストが通らない") })
    }

    @Test func givesUpWhenFixedHeadFailsAgainAfterMaxAttempts() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        for sha in ["s1", "s2", "s3", "s4", "s5"] {
            github.setFailingPullRequests([Self.failing(sha)])
            try await pollAndWait(orchestrator)
        }

        #expect(runtime.ran.count == 3)
        let gaveUp = github.pullRequestComments.filter { $0.contains(CIFixTracker.gaveUpMarker) }
        #expect(gaveUp.count == 1)
        #expect(gaveUp.first?.contains("s4 でも CI が失敗しました") == true)
        #expect(logs.recorded.contains { $0.contains("#50 の CI が s4 でも失敗しましたが、3 回直させたのであきらめます") })
    }

    @Test func waitsForUsageLimitWithoutCountingCIFixAttempt() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([CommandResult(status: 2, output: "Claude AI usage limit reached|\(reset)\n")])
        try await pollAndWait(try makeOrchestrator(github: github, runtime: runtime, now: { clock.now }))
        #expect(github.pullRequestComments.last?.contains(CIFixTracker.cancelMarker("s1")) == true)

        // 取り消しの目印があるので、再起動した後でも解除の後に同じ head で試し直す
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")])
        try await pollAndWait(try makeOrchestrator(github: github, runtime: runtime, now: { clock.now }))
        #expect(runtime.ran.count == 2)
    }

    @Test func doesNotCountAttemptWhenHeadMovedBeforeFix() async throws {
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        runtime.setRunResults([
            CommandResult(status: 0, output: "ASKHUB_RESULT: stale\n"), CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")
        ])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWait(orchestrator)
        try await pollAndWait(orchestrator)

        #expect(runtime.ran.count == 2)
    }

    @Test func doesNotStartWithoutRecordingAttemptOnPullRequest() async throws {
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        github.setPullRequestCommentFails(true)
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWait(orchestrator)
        #expect(runtime.ran.isEmpty)

        github.setPullRequestCommentFails(false)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")])
        try await pollAndWait(orchestrator)
        #expect(runtime.ran.count == 1)
    }

    @Test func leavesFinalPullRequestToLoopWorkingOnSameEpic() async throws {
        let github = FakeGitHub([.success([])])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")])
        runtime.set(LoopStatus(stateFileExists: true, processAlive: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 指示で再開したループが同じ epic を直している間は、push がぶつかるので直させない
        try await pollAndWait(orchestrator)
        #expect(!runtime.ran.contains { $0.first == "/usr/local/bin/askhub-fix-ci" })
        #expect(github.pullRequestComments.isEmpty)

        // 別の epic のループなら、制御用 worktree には触れずに直させる
        runtime.setEpic(EpicSnapshot(branch: "epic/next", goal: nil, state: nil))
        try await pollAndWait(orchestrator)
        #expect(runtime.ran.filter { $0.first == "/usr/local/bin/askhub-fix-ci" }.count == 1)
    }

    @Test func fixesCIOneAtATimeWithConflictResolutionInSameRepository() async throws {
        let github = FakeGitHub([.success([])])
        let conflicting = ConflictingPullRequest(
            repository: "shilokuma-inc/ask-hub-apple", number: 51, headBranch: "epic/other", baseBranch: "dev", headSHA: "h1", baseSHA: "b1"
        )
        github.setConflictingPullRequests([conflicting])
        github.setFailingPullRequests([Self.failing()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // コンフリクトの解消が先。同じリポジトリでは終わるまで CI を直させない
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)
        #expect(runtime.ran.count == 1)
        #expect(runtime.ran.first?.contains("epic/other") == true)

        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        github.setConflictingPullRequests([])
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed\n")])
        try await pollAndWait(orchestrator)
        #expect(runtime.ran.count == 2)
        #expect(runtime.ran.last?.last == "s1")
    }
}
