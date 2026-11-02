@testable import AskHubKit
import Testing

/// 最終 PR の段階と「要対応」に数えるか（Discussion #808）
struct EpicPullRequestFinalStageTests {
    private static let clean = ThirdPartyReviewMarker(sha: "abc123", must: 0, may: 1)

    @Test func mergeableOnlyWhenCanMerge() {
        let pull = EpicPullRequest.fixture()
        #expect(pull.canMerge)
        #expect(pull.finalStage == .mergeable)
        #expect(pull.countsAsActionable)
        // 第三者レビューで要修正 0 件でもレビュー済み
        let reviewed = EpicPullRequest.fixture(codeRabbit: .rateLimited, thirdPartyReview: Self.clean)
        #expect(reviewed.finalStage == .mergeable)
    }

    @Test func waitsForChecksWhilePendingOrNone() {
        #expect(EpicPullRequest.fixture(checks: .pending).finalStage == .waitingForChecks)
        // check run が 1 つも無いときも CI 待ち
        #expect(EpicPullRequest.fixture(checks: .none).finalStage == .waitingForChecks)
        #expect(!EpicPullRequest.fixture(checks: .pending).countsAsActionable)
        #expect(!EpicPullRequest.fixture(checks: .none).countsAsActionable)
    }

    @Test func waitsForChecksWhileRunningEvenIfOneFailed() {
        // 1 つ失敗しても、残りが動いている間は CI 待ち
        let running = EpicPullRequest.fixture(checks: .failure, hasRunningChecks: true)
        #expect(running.finalStage == .waitingForChecks)
        #expect(!running.countsAsActionable)
        // 実行中ならコンフリクトしていても CI 待ち
        let conflicting = EpicPullRequest.fixture(checks: .pending, hasRunningChecks: true, mergeability: .conflicting)
        #expect(conflicting.finalStage == .waitingForChecks)
    }

    @Test func checksFailedAfterAllRunsFinished() {
        let failed = EpicPullRequest.fixture(checks: .failure)
        #expect(failed.finalStage == .checksFailed)
        #expect(failed.countsAsActionable)
        #expect(failed.finalStage.isProblem)
        // コンフリクトと CI 失敗が重なったら CI 失敗（数える）
        let both = EpicPullRequest.fixture(checks: .failure, mergeability: .conflicting)
        #expect(both.finalStage == .checksFailed)
        #expect(both.countsAsActionable)
        // レビュー前でも CI 失敗
        #expect(EpicPullRequest.fixture(checks: .failure, codeRabbit: .inProgress).finalStage == .checksFailed)
    }

    @Test func conflictingAfterChecksPassedIsNotCounted() {
        let pull = EpicPullRequest.fixture(mergeability: .conflicting)
        #expect(pull.finalStage == .conflicting)
        #expect(pull.finalStage.isProblem)
        #expect(!pull.countsAsActionable)
        // レビュー前でもコンフリクトを先に出す
        #expect(EpicPullRequest.fixture(mergeability: .conflicting, codeRabbit: .inProgress).finalStage == .conflicting)
    }

    @Test func waitingForReviewAfterChecksPassed() {
        for state: EpicPullRequest.CodeRabbitState in [.inProgress, .rateLimited, .skipped, .failed, .unknown, .none] {
            let pull = EpicPullRequest.fixture(codeRabbit: state)
            #expect(pull.finalStage == .waitingForReview)
            #expect(!pull.countsAsActionable)
        }
        // 第三者レビューで要修正が残っていればレビュー待ち
        let must = ThirdPartyReviewMarker(sha: "abc123", must: 2, may: 0)
        #expect(EpicPullRequest.fixture(codeRabbit: .none, thirdPartyReview: must).finalStage == .waitingForReview)
        // コンフリクトの有無が未計算でも、レビュー前ならレビュー待ち
        #expect(EpicPullRequest.fixture(mergeability: .unknown, codeRabbit: .none).finalStage == .waitingForReview)
    }

    @Test func checkingMergeabilityIsNotMergeable() {
        let pull = EpicPullRequest.fixture(mergeability: .unknown)
        #expect(!pull.canMerge)
        #expect(pull.finalStage == .checkingMergeability)
        #expect(!pull.countsAsActionable)
        #expect(!pull.finalStage.isProblem)
    }

    @Test func countsOnlyMergeableAndChecksFailed() {
        let counted = EpicPullRequest.FinalStage.allCases.filter(\.countsAsActionable)
        #expect(counted == [.checksFailed, .mergeable])
        let problems = EpicPullRequest.FinalStage.allCases.filter(\.isProblem)
        #expect(problems == [.checksFailed, .conflicting])
        let labels = EpicPullRequest.FinalStage.allCases.map(\.label)
        #expect(labels == ["CI 待ち", "CI 失敗", "コンフリクト", "レビュー待ち", "マージ可否の確認中", "マージ可"])
    }
}
