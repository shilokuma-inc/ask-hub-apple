import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct CIFixTrackerTests {
    private func pullRequest(sha: String = "s1", number: Int = 56) -> FailingPullRequest {
        FailingPullRequest(repository: "shariverse/oshikatsu-countdown-ios", number: number, headBranch: "epic/onboarding", headSHA: sha)
    }

    private func orchestratorComment(_ id: Int, _ lines: String...) -> IssueComment {
        IssueComment(id: id, author: "mrs1669", body: ([FinalPullRequestMarker.orchestrator] + lines).joined(separator: "\n"))
    }

    @Test func triesEachHeadOnceUpToMaxAttemptsThenGivesUp() {
        var tracker = CIFixTracker()
        // 記録を読むまでは何もしない
        #expect(tracker.decision(for: pullRequest()) == .skip)
        tracker.loadHistory(from: [], for: pullRequest())
        #expect(tracker.decision(for: pullRequest()) == .start)

        tracker.start(pullRequest())
        #expect(tracker.isRunning(in: "Shariverse/Oshikatsu-Countdown-iOS"))
        tracker.finish(pullRequest())
        #expect(!tracker.isRunning(in: "shariverse/oshikatsu-countdown-ios"))
        // 同じ head では試し直さない
        #expect(tracker.decision(for: pullRequest()) == .skip)

        for sha in ["s2", "s3"] {
            #expect(tracker.decision(for: pullRequest(sha: sha)) == .start)
            tracker.start(pullRequest(sha: sha))
            tracker.finish(pullRequest(sha: sha))
        }
        #expect(tracker.reachedLimit(pullRequest()))
        // 上限まで試した後に新しい head で失敗したら、あきらめたことを伝える（1 回だけ）
        #expect(tracker.decision(for: pullRequest(sha: "s4")) == .giveUp)
        tracker.giveUp(pullRequest(sha: "s4"))
        #expect(tracker.decision(for: pullRequest(sha: "s5")) == .skip)
    }

    @Test func cancelledAttemptDoesNotCount() {
        var tracker = CIFixTracker()
        tracker.loadHistory(from: [], for: pullRequest())
        tracker.start(pullRequest())
        tracker.cancel(pullRequest())
        tracker.finish(pullRequest())
        #expect(tracker.decision(for: pullRequest()) == .start)
    }

    @Test func readsHistoryFromOrchestratorCommentsOnly() {
        var tracker = CIFixTracker()
        tracker.loadHistory(from: [
            orchestratorComment(1, CIFixTracker.attemptMarker("s1"), "直させます"),
            orchestratorComment(2, CIFixTracker.attemptMarker("s2")),
            // 利用上限で止まった試行は取り消す
            orchestratorComment(3, CIFixTracker.cancelMarker("s2")),
            // オーケストレーターの目印で始まらないコメントの目印は拾わない
            IssueComment(id: 4, author: "someone", body: CIFixTracker.attemptMarker("s9"))
        ], for: pullRequest())

        #expect(tracker.histories[pullRequest().key]?.attemptedSHAs == ["s1"])
        #expect(tracker.decision(for: pullRequest(sha: "s1")) == .skip)
        #expect(tracker.decision(for: pullRequest(sha: "s2")) == .start)
        #expect(tracker.decision(for: pullRequest(sha: "s9")) == .start)
        #expect(!tracker.needsHistory(of: pullRequest()))
    }

    @Test func readsGaveUpFromComments() {
        var tracker = CIFixTracker()
        tracker.loadHistory(from: [orchestratorComment(1, CIFixTracker.gaveUpMarker, "やめます")], for: pullRequest())
        #expect(tracker.decision(for: pullRequest(sha: "new")) == .skip)
    }

    @Test func forgetsPullRequestsThatNoLongerFail() {
        var tracker = CIFixTracker()
        tracker.loadHistory(from: [], for: pullRequest(number: 1))
        tracker.loadHistory(from: [], for: pullRequest(number: 2))
        tracker.prune(keeping: [pullRequest(number: 2)])
        #expect(tracker.needsHistory(of: pullRequest(number: 1)))
        #expect(!tracker.needsHistory(of: pullRequest(number: 2)))
    }

    @Test func readsOutcomeFromLastResultLine() {
        #expect(CIFixTracker.outcome(in: "ASKHUB_RESULT: unresolved 前\nログ\nASKHUB_RESULT: fixed\n") == .fixed)
        #expect(CIFixTracker.outcome(in: "ASKHUB_RESULT: stale") == .stale)
        #expect(CIFixTracker.outcome(in: "ASKHUB_RESULT: unresolved UI テストが不安定") == .unresolved(reason: "UI テストが不安定"))
        #expect(CIFixTracker.outcome(in: "ASKHUB_RESULT: unresolved") == .unresolved(reason: "理由は出力されませんでした"))
        #expect(CIFixTracker.outcome(in: "ASKHUB_RESULT: done") == nil)
        #expect(CIFixTracker.outcome(in: "何も出さずに終わった") == nil)
    }

    @Test func rendersCommandWithHeadSHA() throws {
        let loop = try LoopCommandTemplate(arguments: ["/Users/me/.local/bin/askhub-start-loop", "{repository}"])
        let template = CIFixCommandTemplate.standard(besides: loop)
        let repository = RepositoryConfig(owner: "shariverse", name: "oshikatsu-countdown-ios", checkoutPath: "/src/oshikatsu")
        #expect(template.render(for: repository, pullRequest: pullRequest()) == [
            "/Users/me/.local/bin/askhub-fix-ci", "shariverse/oshikatsu-countdown-ios", "/src/oshikatsu", "epic/onboarding", "56", "s1"
        ])
        #expect(throws: OrchestratorConfigError.unknownCIFixPlaceholder("baseBranch")) {
            try CIFixCommandTemplate(arguments: ["fix", "{baseBranch}"])
        }
        #expect(throws: OrchestratorConfigError.emptyCIFixCommand) {
            try CIFixCommandTemplate(arguments: [])
        }
    }
}
