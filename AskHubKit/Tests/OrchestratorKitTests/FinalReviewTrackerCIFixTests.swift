import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

/// 最終 PR の CI の失敗の修正（`FinalReviewTracker` の `fixCI`）
struct FinalReviewTrackerCIFixTests {
    private static let head1 = String(repeating: "1", count: 40)
    private static let head2 = String(repeating: "2", count: 40)
    private static let head3 = String(repeating: "3", count: 40)
    private static let head4 = String(repeating: "4", count: 40)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/Users/me/.local/bin/askhub-start-loop", "{repository}"])
        )
    }

    private func pullRequest(head: String = head1) -> FinalReviewPullRequest {
        FinalReviewPullRequest(
            repository: "shilokuma-inc/ask-hub-apple", number: 56, headBranch: "epic/onboarding", baseBranch: "develop", headSHA: head
        )
    }

    private func candidate(
        head: String = head1,
        checks: EpicPullRequest.ChecksState = .failure,
        running: Bool = false,
        codeRabbit: EpicPullRequest.CodeRabbitState = .inProgress,
        ciFix: CIFixRecord = CIFixRecord()
    ) -> FinalReviewCandidate {
        FinalReviewCandidate(
            pullRequest: pullRequest(head: head),
            codeRabbit: codeRabbit,
            isConflicting: false,
            checks: checks,
            hasRunningChecks: running,
            ciFix: ciFix
        )
    }

    private func actions(_ tracker: FinalReviewTracker, _ candidate: FinalReviewCandidate) throws -> [FinalReviewTracker.Action] {
        try tracker.startable(in: [candidate], config: config(), now: now).map(\.action)
    }

    @Test func fixesFailedCIOnceAllChecksFinishEvenAfterCodeRabbitReviewed() throws {
        var tracker = FinalReviewTracker()
        // 失敗していても、終わっていない check run があるうちは直させない（ログが揃っていない）
        let running = candidate(running: true)
        tracker.update(with: [running], now: now)
        #expect(try actions(tracker, running).isEmpty)

        // すべて終わったら、CodeRabbit がレビューした後でも直させる
        let failed = candidate(codeRabbit: .completed)
        tracker.update(with: [failed], now: now)
        #expect(try actions(tracker, failed) == [.fixCI])

        // 成功・実行中の CI では直させない
        for checks in [EpicPullRequest.ChecksState.success, .pending, .none] {
            let other = candidate(checks: checks, codeRabbit: .completed)
            tracker.update(with: [other], now: now)
            #expect(try actions(tracker, other).isEmpty)
        }
    }

    @Test func triesEachHeadOnceAndCarriesOverAfterOwnPush() throws {
        var tracker = FinalReviewTracker()
        let failed = candidate()
        tracker.update(with: [failed], now: now)
        tracker.start(.fixCI, for: pullRequest())
        tracker.finish(pullRequest())
        // PR のコメントの目印がまだ見えなくても、同じ head では二重に始めない（CodeRabbit を待つ間はレビューも始めない）
        tracker.update(with: [failed], now: now)
        #expect(try actions(tracker, failed).isEmpty)

        tracker.start(.fixCI, for: pullRequest())
        tracker.recordCIFix(.fixed(head: Self.head2), for: pullRequest())
        tracker.finish(pullRequest())
        #expect(try actions(tracker, failed).isEmpty)
        // 直した head でまた失敗したら、次を試す
        let again = candidate(head: Self.head2, ciFix: CIFixRecord(attemptedSHAs: [Self.head1]))
        tracker.update(with: [again], now: now)
        #expect(try actions(tracker, again) == [.fixCI])
    }

    @Test func readsAttemptsFromPullRequestAfterRestart() throws {
        var tracker = FinalReviewTracker()
        // 再起動した後も、目印のある head では試さない
        let tried = candidate(codeRabbit: .completed, ciFix: CIFixRecord(attemptedSHAs: [Self.head1]))
        tracker.update(with: [tried], now: now)
        #expect(try actions(tracker, tried).isEmpty)
        #expect(tracker.ciFixGiveUps(in: [tried]).isEmpty)
    }

    @Test func givesUpAfterMaxAttempts() throws {
        var tracker = FinalReviewTracker()
        let record = CIFixRecord(attemptedSHAs: [Self.head1, Self.head2, Self.head3])
        let failed = candidate(head: Self.head4, codeRabbit: .completed, ciFix: record)
        tracker.update(with: [failed], now: now)
        #expect(try actions(tracker, failed).isEmpty)
        #expect(tracker.reachedCIFixLimit(failed))
        // あきらめたことを 1 回だけ伝える
        #expect(tracker.ciFixGiveUps(in: [failed]) == [failed.pullRequest])
        tracker.giveUpCIFix(failed.pullRequest)
        #expect(tracker.ciFixGiveUps(in: [failed]).isEmpty)
        // 目印で伝え済みなら、再起動した後も伝えない
        var restarted = FinalReviewTracker()
        let told = candidate(head: Self.head4, ciFix: CIFixRecord(attemptedSHAs: record.attemptedSHAs, gaveUp: true))
        restarted.update(with: [told], now: now)
        #expect(restarted.ciFixGiveUps(in: [told]).isEmpty)
        #expect(try actions(restarted, told).isEmpty)
    }

    @Test func cancelledOrStaleAttemptDoesNotCount() throws {
        var tracker = FinalReviewTracker()
        let failed = candidate()
        tracker.update(with: [failed], now: now)
        tracker.start(.fixCI, for: pullRequest())
        tracker.cancelCIFix(pullRequest())
        tracker.finish(pullRequest())
        #expect(try actions(tracker, failed) == [.fixCI])

        // head が進んでいた（stale）なら、新しい head が見えるまで待ち、新しい head で試す
        tracker.start(.fixCI, for: pullRequest())
        tracker.recordCIFix(.stale, for: pullRequest())
        tracker.finish(pullRequest())
        #expect(try actions(tracker, failed).isEmpty)
        let moved = candidate(head: Self.head2)
        tracker.update(with: [moved], now: now)
        #expect(try actions(tracker, moved) == [.fixCI])
    }

    @Test func failedAttemptIsNotRetriedOnSameHead() throws {
        var tracker = FinalReviewTracker()
        let failed = candidate(codeRabbit: .completed)
        tracker.update(with: [failed], now: now)
        tracker.start(.fixCI, for: pullRequest())
        tracker.recordCIFix(.failed(reason: "原因が分からない"), for: pullRequest())
        tracker.finish(pullRequest())
        #expect(try actions(tracker, failed).isEmpty)
        #expect(!tracker.reachedCIFixLimit(failed))
    }
}
