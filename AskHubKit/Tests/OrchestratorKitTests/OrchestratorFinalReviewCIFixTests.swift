import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR の CI の失敗の修正

extension OrchestratorTests {
    private static let ciHead1 = String(repeating: "c", count: 40)
    private static let ciHead2 = String(repeating: "d", count: 40)
    private static let ciFixScript = "/usr/local/bin/askhub-fix-ci"

    private static func failingCandidate(
        head: String = ciHead1,
        running: Bool = false,
        ciFix: CIFixRecord = CIFixRecord()
    ) -> FinalReviewCandidate {
        FinalReviewCandidate(
            pullRequest: FinalReviewPullRequest(
                repository: "shilokuma-inc/ask-hub-apple", number: 56, headBranch: "epic/onboarding", baseBranch: "develop", headSHA: head
            ),
            // CodeRabbit がレビューした後でも、CI の失敗は直させる
            codeRabbit: .completed,
            isConflicting: false,
            checks: .failure,
            hasRunningChecks: running,
            ciFix: ciFix
        )
    }

    /// 1 回ポーリングし、裏の修正が終わるまで待つ
    private func pollAndWaitForCIFix(_ orchestrator: Orchestrator) async throws {
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
    }

    private func ciFixRuns(_ runtime: FakeRuntime) -> [[String]] {
        runtime.ran.filter { $0.first == Self.ciFixScript }
    }

    @Test func fixesFailedCIOfFinalPullRequestAndRecordsAttemptFirst() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.failingCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "直しました\nASKHUB_RESULT: fixed \(Self.ciHead2)\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)
        // push の後も、新しい head が見えるまでは同じ head で直し直さない
        try await pollAndWaitForCIFix(orchestrator)

        let expected = [
            Self.ciFixScript, "shilokuma-inc/ask-hub-apple", "/src/ask-hub-apple", "epic/onboarding", "develop", "56", Self.ciHead1
        ]
        #expect(ciFixRuns(runtime) == [expected])
        #expect(runtime.runEnvironments.first?["ASKHUB_TRUSTED_AUTHORS"] == "mrs1669")
        // 試すことを先に PR に残し（再起動しても同じ head で試し直さない）、結果も伝える
        let attempt = try #require(CIFixMarker(action: .attempt, sha: Self.ciHead1).htmlComment)
        let prefix = "shilokuma-inc/ask-hub-apple#56: \(FinalPullRequestMarker.orchestrator)\n"
        #expect(github.pullRequestComments.count == 2)
        #expect(github.pullRequestComments.first?.hasPrefix("\(prefix)\(attempt)\n") == true)
        #expect(github.pullRequestComments.last?.hasPrefix("\(prefix)CI の失敗を直し、epic/onboarding に push しました") == true)
        #expect(logs.recorded.contains { $0.contains("#56（ccccccc）の CI の失敗の修正を始めます") })
    }

    @Test func waitsForRunningChecksBeforeFixingCI() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.failingCandidate(running: true)])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)

        #expect(runtime.ran.isEmpty)
        #expect(github.pullRequestComments.isEmpty)
    }

    @Test func doesNotRetryCIFixOfSameHeadAfterRestart() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.failingCandidate(ciFix: CIFixRecord(attemptedSHAs: [Self.ciHead1]))])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)

        #expect(ciFixRuns(runtime).isEmpty)
    }

    @Test func tellsWhyCIFixFailedAndGivesUpAtLimit() async throws {
        let github = FakeGitHub([.success([])])
        let record = CIFixRecord(attemptedSHAs: [String(repeating: "1", count: 40), String(repeating: "2", count: 40)])
        github.setFinalReviewCandidates([Self.failingCandidate(ciFix: record)])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 2, output: "ASKHUB_RESULT: failed UI テストが通らない\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)

        // 3 回目も直せなかったので、理由と、自動の修正をやめることを伝える
        let gaveUp = try #require(CIFixMarker(action: .gaveUp, sha: Self.ciHead1).htmlComment)
        #expect(github.pullRequestComments.last?.contains("\(gaveUp)\nCI の失敗を自動で直せませんでした: UI テストが通らない") == true)
        #expect(github.pullRequestComments.last?.contains("3 回直させたので、自動の修正をやめます") == true)
        #expect(logs.recorded.contains { $0.contains("#56 の CI の失敗を直せませんでした（自動の修正をやめます）: UI テストが通らない") })
    }

    @Test func tellsGiveUpWhenCIFailsAgainAfterLimit() async throws {
        let github = FakeGitHub([.success([])])
        let record = CIFixRecord(attemptedSHAs: ["1", "2", "3"].map { String(repeating: $0, count: 40) })
        github.setFinalReviewCandidates([Self.failingCandidate(ciFix: record)])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)
        try await pollAndWaitForCIFix(orchestrator)

        #expect(ciFixRuns(runtime).isEmpty)
        let gaveUp = try #require(CIFixMarker(action: .gaveUp, sha: Self.ciHead1).htmlComment)
        #expect(github.pullRequestComments.filter { $0.contains(gaveUp) }.count == 1)
        #expect(logs.recorded.contains { $0.contains("#56 の CI が ccccccc でも失敗しましたが、3 回直させたので自動の修正をやめます") })
    }

    @Test func cancelsCIFixAttemptStoppedByUsageLimit() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.failingCandidate()])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([CommandResult(status: 2, output: "Claude AI usage limit reached|\(reset)\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await pollAndWaitForCIFix(orchestrator)
        let cancel = try #require(CIFixMarker(action: .cancel, sha: Self.ciHead1).htmlComment)
        #expect(github.pullRequestComments.last?.contains(cancel) == true)

        // 解除の後に、同じ head で試し直す
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(Self.ciHead2)\n")])
        try await pollAndWaitForCIFix(orchestrator)
        #expect(ciFixRuns(runtime).count == 2)
    }

    @Test func doesNotStartCIFixWithoutRecordingAttempt() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.failingCandidate()])
        github.setPullRequestCommentFails(true)
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(Self.ciHead2)\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await pollAndWaitForCIFix(orchestrator)
        #expect(ciFixRuns(runtime).isEmpty)

        github.setPullRequestCommentFails(false)
        try await pollAndWaitForCIFix(orchestrator)
        #expect(ciFixRuns(runtime).count == 1)
    }

    @Test func fixesCIAfterConflictResolutionInSameRepository() async throws {
        let github = FakeGitHub([.success([])])
        let conflicting = ConflictingPullRequest(
            repository: "shilokuma-inc/ask-hub-apple", number: 51, headBranch: "epic/other", baseBranch: "dev", headSHA: "h", baseSHA: "b"
        )
        github.setConflictingPullRequests([conflicting])
        github.setFinalReviewCandidates([Self.failingCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 同じリポジトリでは、コンフリクトの解消が終わるまで CI を直させない（同じ checkout に一時 worktree を作るため）
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)
        #expect(runtime.ran.count == 1)
        #expect(ciFixRuns(runtime).isEmpty)

        github.setConflictingPullRequests([])
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(Self.ciHead2)\n")])
        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        try await pollAndWaitForCIFix(orchestrator)
        #expect(ciFixRuns(runtime).count == 1)
    }
}
