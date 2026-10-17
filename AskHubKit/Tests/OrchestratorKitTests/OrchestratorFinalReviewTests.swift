import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR の第三者レビュー（Discussion #503）

extension OrchestratorTests {
    private static let head1 = String(repeating: "a", count: 40)
    private static let head2 = String(repeating: "b", count: 40)

    private static func finalCandidate(
        number: Int = 70,
        head: String = head1,
        codeRabbit: EpicPullRequest.CodeRabbitState = .rateLimited,
        isConflicting: Bool = false
    ) -> FinalReviewCandidate {
        FinalReviewCandidate(
            pullRequest: FinalReviewPullRequest(
                repository: "shilokuma-inc/ask-hub-apple",
                number: number,
                headBranch: "epic/e\(number)",
                baseBranch: "develop",
                headSHA: head
            ),
            codeRabbit: codeRabbit,
            isConflicting: isConflicting
        )
    }

    private static let conflictingMVP = ConflictingPullRequest(
        repository: "shilokuma-inc/ask-hub-apple", number: 50, headBranch: "epic/mvp", baseBranch: "develop", headSHA: "h1", baseSHA: "b1"
    )

    /// 裏のレビュー・修正がすべて終わる（次も始まらない）まで待つ。数秒で諦める
    private func waitUntilNoFinalReview(_ orchestrator: Orchestrator) async {
        var waited = 0
        while await !orchestrator.finalReviews.isEmpty, waited < 5_000 {
            try? await Task.sleep(for: .milliseconds(1))
            waited += 1
        }
    }

    @Test func reviewsFinalPullRequestWhenCodeRabbitCannotReview() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=1\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        let expected = [
            "/usr/local/bin/askhub-review-final", "shilokuma-inc/ask-hub-apple", "/src/ask-hub-apple",
            "epic/e70", "develop", "70", Self.head1
        ]
        #expect(runtime.ran == [expected])
        // 前回の第三者レビューを信用する author のものだけ読むよう、信用する author とモデルを渡す
        #expect(runtime.runEnvironments.first?["ASKHUB_TRUSTED_AUTHORS"] == "mrs1669")
        #expect(runtime.runEnvironments.first?["ANTHROPIC_MODEL"] != nil)
        // コメントはスクリプトが付ける。済みになったら同じ head はレビューし直さない
        #expect(github.pullRequestComments.isEmpty)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 1)
        #expect(logs.recorded.contains { $0.contains("#70 の第三者レビューが終わりました（要修正 0 件・提案 1 件）") })
    }

    @Test func waitsTenMinutesForCodeRabbitBeforeStartingReview() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate(codeRabbit: .inProgress)])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await orchestrator.pollOnce()
        clock.now = clock.now.addingTimeInterval(9 * 60)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.isEmpty)

        clock.now = clock.now.addingTimeInterval(60)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 1)
    }

    @Test func fixesMustFixItemsAndReviewsPushedHead() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=2 may=0\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        // 要修正があれば、次のポーリングで直させる
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(Self.head2)\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 2)
        #expect(runtime.ran.last?.first == "/usr/local/bin/askhub-fix-review")
        #expect(runtime.ran.last?.last == Self.head1)

        // push で head が変わったら、新しい head をレビューする（CodeRabbit がまだレビューしていなければ）
        github.setFinalReviewCandidates([Self.finalCandidate(head: Self.head2, codeRabbit: .rateLimited)])
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 3)
        #expect(runtime.ran.last?.first == "/usr/local/bin/askhub-review-final")
        #expect(runtime.ran.last?.last == Self.head2)
        #expect(await orchestrator.finalReviewTracker.marker(for: Self.finalCandidate(head: Self.head2).pullRequest)?.state == .done)
    }

    @Test func tellsPullRequestWhenGivingUp() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 2, output: "ASKHUB_RESULT: failed 差分が空です\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        for _ in 0..<FinalReviewTracker.maxFailures + 1 {
            try await orchestrator.pollOnce()
            await orchestrator.waitForConflictResolutions()
        }

        // 3 回続けて失敗したらあきらめ、PR に知らせる（それ以上は試さない）
        #expect(runtime.ran.count == FinalReviewTracker.maxFailures)
        #expect(github.pullRequestComments.count == 1)
        let comment = try #require(github.pullRequestComments.first)
        #expect(comment.hasPrefix("shilokuma-inc/ask-hub-apple#70: 第三者レビューによる自動の修正をやめます（aaaaaaa）"))
        #expect(comment.contains("差分が空です"))
        #expect(comment.contains("GitHub の画面からはマージできます"))
    }

    @Test func doesNotReviewWhileConflictIsBeingResolvedInSameRepository() async throws {
        let github = FakeGitHub([.success([])])
        github.setConflictingPullRequests([Self.conflictingMVP])
        github.setFinalReviewCandidates([Self.finalCandidate(number: 70)])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: resolved\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 同じリポジトリでは、コンフリクトの解消を先に始め、第三者レビューは始めない（同じ checkout に一時 worktree を作るため）
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)
        #expect(runtime.ran.count == 1)
        #expect(runtime.ran.first?.contains("epic/mvp") == true)
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)

        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        github.setConflictingPullRequests([])
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 2)
        #expect(runtime.ran.last?.contains("epic/e70") == true)
    }

    @Test func doesNotResolveConflictWhileReviewRunsInSameRepository() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate(number: 70)])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)

        // レビューしている間にほかの最終 PR がコンフリクトしても、同じリポジトリでは解消を始めない
        github.setConflictingPullRequests([Self.conflictingMVP])
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)

        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 2)
        #expect(runtime.ran.last?.contains("epic/mvp") == true)
    }

    @Test func waitsForUsageLimitWithoutCountingReviewAttempt() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([CommandResult(status: 2, output: "Claude AI usage limit reached|\(reset)\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await orchestrator.pollOnce()
        await waitUntilNoFinalReview(orchestrator)
        // 利用上限中は始めない
        try await orchestrator.pollOnce()
        await waitUntilNoFinalReview(orchestrator)
        #expect(runtime.ran.count == 1)
        #expect(await orchestrator.finalReviewTracker.marker(for: Self.finalCandidate().pullRequest)?.state == .waiting)

        // 解除の後に試し直す（試したことに数えていない）
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 2)
        #expect(github.pullRequestComments.isEmpty)
    }
}
