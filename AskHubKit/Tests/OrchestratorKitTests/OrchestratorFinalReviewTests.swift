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

    @Test func givesUpAndTellsAfterThreeReviewsWithMustFixItems() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        let heads = [Self.head1, Self.head2, String(repeating: "c", count: 40)]
        for (index, head) in heads.enumerated() {
            // レビューで要修正があり、直して push すると次の head になる（自分の push なので回数を引き継ぐ）
            github.setFinalReviewCandidates([Self.finalCandidate(head: head)])
            runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=1 may=0\n")])
            try await orchestrator.pollOnce()
            await orchestrator.waitForConflictResolutions()
            if index < heads.count - 1 {
                runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(heads[index + 1])\n")])
                try await orchestrator.pollOnce()
                await orchestrator.waitForConflictResolutions()
            }
        }

        // 要修正が 3 回続いたらあきらめ、PR に知らせる（Q1）。それ以上は直さない
        #expect(runtime.ran.count == 5)
        #expect(github.pullRequestComments.count == 1)
        let comment = try #require(github.pullRequestComments.first)
        #expect(comment.contains("第三者レビューの要修正が 3 回続けて収まりませんでした（最新のレビューで要修正 1 件）"))
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 5)
    }

    @Test func keepsFinishedResultEvenIfOutputMentionsUsageLimit() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        let reset = Int(Date(timeIntervalSince1970: 1_800_000_000).timeIntervalSince1970) + 3600
        // claude の出力の末尾に利用上限の文言が混ざっても、レビューが終わっていれば結果を使う（投稿済みのレビューを捨てない）
        runtime.setRunResults([
            CommandResult(status: 0, output: "Claude AI usage limit reached|\(reset)\nASKHUB_RESULT: reviewed must=0 may=0\n")
        ])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        #expect(await orchestrator.finalReviewTracker.marker(for: Self.finalCandidate().pullRequest)?.state == .done)
        #expect(await orchestrator.usageLimitedUntil == nil)
    }

    @Test func treatsFixReturningSameHeadAsFailureAndWaitsAfterStale() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=1 may=0\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        // 今の head と同じ SHA を「直した」と返したら、失敗として直し直す
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: fixed \(Self.head1)\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(logs.recorded.contains { $0.contains("要修正を直せませんでした（次のポーリングで試し直します）: 今の head と同じ SHA を直したと返しました") })

        // head が進んでいた（stale）なら、新しい head が見えるまで同じ head では始めない
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: stale\n")])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(runtime.ran.count == 3)
    }

    // MARK: - 進み具合の状態コメント

    @Test func writesOneStatusCommentAndRewritesItWhenStateChanges() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        runtime.setHoldsRuns(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // レビューを始めたら、目印付きの状態コメントを 1 件作る
        try await orchestrator.pollOnce()
        await runtime.waitForHeldRuns(1)
        #expect(github.createdComments.count == 1)
        let reviewing = try #require(try await github.comments(in: "shilokuma-inc/ask-hub-apple", issue: 70).first)
        #expect(FinalReviewMarker.parse(reviewing.body) == FinalReviewMarker(state: .reviewing, sha: Self.head1))
        #expect(reviewing.body.contains("第三者レビューの進み具合: レビュー中"))

        // 終わったら同じコメントを書き換える（増やさない）
        runtime.setHoldsRuns(false)
        await orchestrator.waitForConflictResolutions()
        let comments = try await github.comments(in: "shilokuma-inc/ask-hub-apple", issue: 70)
        #expect(comments.count == 1)
        #expect(FinalReviewMarker.parse(comments[0].body)?.state == .done)
        #expect(github.updatedComments == ["shilokuma-inc/ask-hub-apple \(comments[0].id)"])

        // 同じ内容は書き直さない
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(github.createdComments.count == 1)
        #expect(github.updatedComments.count == 1)
    }

    @Test func doesNotCreateStatusCommentWhileCodeRabbitCanReview() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate(codeRabbit: .inProgress)])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // CodeRabbit を待っている間と、CodeRabbit がレビューしたときは、コメントを作らない
        try await orchestrator.pollOnce()
        github.setFinalReviewCandidates([Self.finalCandidate(codeRabbit: .completed)])
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        #expect(runtime.ran.isEmpty)
        #expect(github.createdComments.isEmpty)
        #expect(github.updatedComments.isEmpty)
    }

    @Test func rewritesTrustedStatusCommentLeftBeforeRestart() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate(codeRabbit: .completed)])
        // 再起動の前に書いた状態コメントと、信用しない author が真似たコメント
        let old = try #require(FinalReviewMarker(state: .reviewing, sha: Self.head1).htmlComment)
        github.setIssueComments([
            IssueComment(id: 11, author: "mrs1669", body: old),
            IssueComment(id: 12, author: "someone", body: old)
        ], issue: 70)
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        // CodeRabbit がレビューしたので、信用する author の状態コメントを済み（CodeRabbit）に書き換える（作らない）
        #expect(github.createdComments.isEmpty)
        #expect(github.updatedComments == ["shilokuma-inc/ask-hub-apple 11"])
        let comments = try await github.comments(in: "shilokuma-inc/ask-hub-apple", issue: 70)
        #expect(FinalReviewMarker.parse(comments[0].body)?.state == .doneCodeRabbit)
        #expect(comments[1].body == old)
    }

    @Test(arguments: [404, 403])
    func recreatesStatusCommentThatCannotBeRewritten(status: Int) async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        // 前に書いた状態コメントが消された（404）か、書き換えられない（403。人が書いた目印付きのコメントなど）
        let old = try #require(FinalReviewMarker(state: .reviewing, sha: Self.head1).htmlComment)
        github.setIssueComments([IssueComment(id: 11, author: "mrs1669", body: old)], issue: 70)
        github.setCommentUpdateFailure(id: 11, status: status)
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        // その id は忘れて、新しい状態コメントを作る（同じコメントを書き換えようとし続けない）
        #expect(github.createdComments.count == 1)
        let comments = try await github.comments(in: "shilokuma-inc/ask-hub-apple", issue: 70)
        #expect(FinalReviewMarker.parse(comments.last?.body ?? "")?.state == .done)
        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()
        #expect(github.createdComments.count == 1)
    }

    @Test func keepsStatusCommentWhenRewriteHitsSecondaryRateLimit() async throws {
        let github = FakeGitHub([.success([])])
        github.setFinalReviewCandidates([Self.finalCandidate()])
        let old = try #require(FinalReviewMarker(state: .reviewing, sha: Self.head1).htmlComment)
        github.setIssueComments([IssueComment(id: 11, author: "mrs1669", body: old)], issue: 70)
        // ヘッダーの無い 403 でも、セカンダリレート制限ならコメントは使えるので作り直さない
        github.setCommentUpdateFailure(id: 11, status: 403, message: "You have exceeded a secondary rate limit")
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: reviewed must=0 may=0\n")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        await orchestrator.waitForConflictResolutions()

        #expect(github.createdComments.isEmpty)
        #expect(logs.recorded.contains { $0.contains("#70 に第三者レビューの進み具合を書き出せませんでした") })
    }

    @Test func statusBodyUsesTrackerSettings() throws {
        let body = try #require(Orchestrator.statusBody(FinalReviewMarker(state: .fixing, sha: Self.head1, attempts: 1)))
        #expect(body.hasPrefix(#"<!-- ask-hub:final-review state="fixing" sha="\#(Self.head1)" attempts="1" -->"#))
        #expect(body.contains("\(FinalReviewTracker.codeRabbitWait.components.seconds / 60) 分経っても"))
        #expect(body.contains("要修正が \(FinalReviewTracker.maxAttempts) 回続いたら"))
    }
}
