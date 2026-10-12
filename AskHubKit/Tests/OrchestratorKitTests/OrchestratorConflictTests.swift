import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - 最終 PR のコンフリクトの解消

extension OrchestratorTests {
    private static let conflicting = ConflictingPullRequest(
        repository: "shilokuma-inc/ask-hub-apple", number: 50, headBranch: "epic/mvp", baseBranch: "develop", headSHA: "h1", baseSHA: "b1"
    )

    private static func conflicting(_ repository: String, _ number: Int, head: String) -> ConflictingPullRequest {
        ConflictingPullRequest(
            repository: repository, number: number, headBranch: head, baseBranch: "develop", headSHA: "h\(number)", baseSHA: "b1"
        )
    }

    private static let twoRepositories = [
        RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
        RepositoryConfig(owner: "shilokuma-inc", name: "prime-pick-ios", checkoutPath: "/src/prime-pick-ios")
    ]

    @Test func resolvesConflictingFinalPullRequestAndTellsIt() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "解消しました\nASKHUB_RESULT: resolved\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        // 同じ組み合わせでは試し直さない
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

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
        await orchestrator.waitForConflictResolutions()

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
        await orchestrator.waitForConflictResolutions()

        // 試したことにせず、PR にもコメントしない（解除の後に試し直す）
        #expect(github.pullRequestComments.isEmpty)
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 2)
    }

    // MARK: - 裏の処理

    @Test func keepsPollingWhileConflictIsBeingResolved() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 解消の終わりを待たずにポーリングが戻る
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)
        #expect(runtime.ran.count == 1)
        #expect(github.pullRequestComments.isEmpty)

        // 解消している間のポーリングでは、同じ PR を二重に解消しない
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)

        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        #expect(github.pullRequestComments.count == 1)
        #expect(github.pullRequestComments.first?.hasPrefix("shilokuma-inc/ask-hub-apple#50: ") == true)
    }

    @Test func resolvesOneAtATimePerRepositoryAndOtherRepositoriesInParallel() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([
            Self.conflicting("shilokuma-inc/ask-hub-apple", 50, head: "epic/auto"),
            Self.conflicting("shilokuma-inc/ask-hub-apple", 51, head: "epic/manual"),
            Self.conflicting("shilokuma-inc/prime-pick-ios", 60, head: "epic/other")
        ])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, repositories: Self.twoRepositories)

        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(2)
        // 別のリポジトリは並列に、同じリポジトリは 1 件ずつ
        #expect(Set(runtime.ran.compactMap { $0.first { $0.hasPrefix("epic/") } }) == ["epic/auto", "epic/other"])

        // 終わったら、同じリポジトリの次の PR を次のポーリングを待たずに始める
        runtime.releaseHeldRuns()
        await runtime.waitForHeldRuns(1)
        #expect(runtime.ran.count == 3)
        #expect(runtime.ran.last?.contains("epic/manual") == true)

        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        #expect(github.pullRequestComments.map { $0.prefix { $0 != ":" } }.sorted() == [
            "shilokuma-inc/ask-hub-apple#50", "shilokuma-inc/ask-hub-apple#51", "shilokuma-inc/prime-pick-ios#60"
        ])
    }

    @Test func doesNotStartNextResolutionAfterUsageLimit() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([
            Self.conflicting("shilokuma-inc/ask-hub-apple", 50, head: "epic/auto"),
            Self.conflicting("shilokuma-inc/ask-hub-apple", 51, head: "epic/manual")
        ])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([
            CommandResult(status: 2, output: "Claude AI usage limit reached|\(reset)\n"),
            CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")
        ])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        // 利用上限が解除されるまで、同じリポジトリの次の PR も始めない
        #expect(runtime.ran.count == 1)
        #expect(github.pullRequestComments.isEmpty)
    }

    @Test func runWaitsForConflictResolutionBeforeReturning() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflicting])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        let returned = OSAllocatedUnfairLock(initialState: false)

        // 1 回ポーリングしたら終わる
        let running = Task {
            await orchestrator.run { _ in throw CancellationError() }
            returned.withLock { $0 = true }
        }
        await runtime.waitForHeldRuns(1)
        try await Task.sleep(for: .milliseconds(20))
        // 解消の結果をコメントするまで戻らない（子プロセスはオーケストレーターの終了で止まらないため）
        #expect(!returned.withLock { $0 })

        runtime.setHoldsRuns(false)
        await running.value
        #expect(returned.withLock { $0 })
        #expect(github.pullRequestComments.count == 1)
    }
}
