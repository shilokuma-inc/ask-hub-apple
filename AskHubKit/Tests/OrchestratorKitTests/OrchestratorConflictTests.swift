import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR のコンフリクトの解消

extension OrchestratorTests {
    private static let conflicting = ConflictingPullRequest(
        repository: "shilokuma-inc/ask-hub-apple", number: 50, headBranch: "epic/mvp", baseBranch: "develop", headSHA: "h1", baseSHA: "b1"
    )

    @Test func resolvesConflictingFinalPullRequestAndTellsIt() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "解消しました\nASKHUB_RESULT: resolved\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        // 同じ組み合わせでは試し直さない
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == 1)
        #expect(runtime.ran.first?.contains("epic/mvp") == true)
        #expect(github.pullRequestComments.count == 1)
        #expect(github.pullRequestComments.first?.hasPrefix("shilokuma-inc/ask-hub-apple#50: develop とのコンフリクトを解消し") == true)
    }

    @Test func tellsWhyConflictCouldNotBeResolved() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 2, output: "ASKHUB_RESULT: unresolved 意図が両立しない\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(github.pullRequestComments.first?.contains("自動で解消できませんでした: 意図が両立しない") == true)
        #expect(logs.recorded.contains { $0.contains("#50 のコンフリクトを解消できませんでした（組み合わせが変わったら試し直します）") })
    }

    @Test func waitsForUsageLimitWithoutCountingConflictAttempt() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([CommandResult(status: 2, output: "Claude AI usage limit reached|\(reset)\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await orchestrator.pollOnce()

        // 試したことにせず、PR にもコメントしない（解除の後に試し直す）
        #expect(github.pullRequestComments.isEmpty)
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 2)
    }
}
