import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct FinalReviewTrackerTests {
    private static let head1 = String(repeating: "1", count: 40)
    private static let head2 = String(repeating: "2", count: 40)
    private static let head3 = String(repeating: "3", count: 40)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [
                RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
                RepositoryConfig(owner: "shilokuma-inc", name: "notti-ios", checkoutPath: "/src/notti-ios")
            ],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/Users/me/.local/bin/askhub-start-loop", "{repository}"])
        )
    }

    private func pullRequest(
        repository: String = "shilokuma-inc/ask-hub-apple", number: Int = 503, head: String = head1
    ) -> FinalReviewPullRequest {
        FinalReviewPullRequest(
            repository: repository, number: number, headBranch: "epic/final-review", baseBranch: "develop", headSHA: head
        )
    }

    private func candidate(
        _ pullRequest: FinalReviewPullRequest,
        codeRabbit: EpicPullRequest.CodeRabbitState = .inProgress,
        isConflicting: Bool = false,
        review: ThirdPartyReviewMarker? = nil
    ) -> FinalReviewCandidate {
        FinalReviewCandidate(pullRequest: pullRequest, codeRabbit: codeRabbit, isConflicting: isConflicting, thirdPartyReview: review)
    }

    private func minutes(_ value: Double) -> Date {
        start.addingTimeInterval(value * 60)
    }

    /// 今から始めることの一覧（PR 番号と行うこと）
    private func actions(
        _ tracker: FinalReviewTracker, _ candidates: [FinalReviewCandidate], at date: Date, busy: Set<String> = []
    ) throws -> [String] {
        try tracker.startable(in: candidates, config: config(), now: date, busyRepositories: busy)
            .map { "\($0.pullRequest.number):\($0.action)" }
    }

    @Test func waitsTenMinutesForCodeRabbitBeforeReviewing() throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest())]
        tracker.update(with: candidates, now: start)

        #expect(tracker.marker(for: pullRequest()) == FinalReviewMarker(state: .waiting, sha: Self.head1))
        #expect(try actions(tracker, candidates, at: minutes(9)).isEmpty)
        // 取得し直しても、待ち始めた時刻は変わらない
        tracker.update(with: candidates, now: minutes(5))
        #expect(try actions(tracker, candidates, at: minutes(10)) == ["503:review"])
    }

    @Test(arguments: [EpicPullRequest.CodeRabbitState.rateLimited, .failed, .skipped])
    func reviewsImmediatelyWhenCodeRabbitCannotReview(state: EpicPullRequest.CodeRabbitState) throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: state)]
        tracker.update(with: candidates, now: start)
        #expect(try actions(tracker, candidates, at: start) == ["503:review"])
    }

    @Test(arguments: [EpicPullRequest.CodeRabbitState.inProgress, .unknown, .none])
    func waitsWhenCodeRabbitMayStillReview(state: EpicPullRequest.CodeRabbitState) throws {
        // 処理中・文言が分からない・commit status が無い（CodeRabbit が入っていない）ときは 10 分待つ
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: state)]
        tracker.update(with: candidates, now: start)
        #expect(try actions(tracker, candidates, at: minutes(9.9)).isEmpty)
        #expect(try actions(tracker, candidates, at: minutes(10)) == ["503:review"])
    }

    @Test func reviewedWithoutMustFixItemsIsDone() throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: .rateLimited)]
        tracker.update(with: candidates, now: start)
        tracker.start(.review, for: pullRequest())
        #expect(tracker.marker(for: pullRequest())?.state == .reviewing)
        #expect(tracker.isRunning(in: "Shilokuma-Inc/Ask-Hub-Apple"))
        tracker.record(.reviewed(must: 0, may: 2), for: pullRequest())
        tracker.finish(pullRequest())

        #expect(tracker.marker(for: pullRequest()) == FinalReviewMarker(state: .done, sha: Self.head1))
        #expect(!tracker.isRunning(in: "shilokuma-inc/ask-hub-apple"))
        #expect(try actions(tracker, candidates, at: minutes(30)).isEmpty)
    }

    @Test func fixesMustFixItemsAndReviewsTheFixedHead() throws {
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .rateLimited)], now: start)
        tracker.start(.review, for: pullRequest())
        tracker.record(.reviewed(must: 2, may: 0), for: pullRequest())
        tracker.finish(pullRequest())
        #expect(tracker.marker(for: pullRequest()) == FinalReviewMarker(state: .fixing, sha: Self.head1, attempts: 1))
        #expect(try actions(tracker, [candidate(pullRequest(), codeRabbit: .rateLimited)], at: start) == ["503:fix"])

        tracker.start(.fix, for: pullRequest())
        tracker.record(.fixed(head: Self.head2.uppercased()), for: pullRequest())
        tracker.finish(pullRequest())
        // push の後、新しい head が見えるまで直し直さない
        #expect(try actions(tracker, [candidate(pullRequest(), codeRabbit: .rateLimited)], at: start).isEmpty)

        // 修正の push で head が変わった: 待ち始めからやり直し、回数は引き継ぐ
        let fixed = pullRequest(head: Self.head2)
        tracker.update(with: [candidate(fixed)], now: minutes(20))
        #expect(tracker.marker(for: fixed) == FinalReviewMarker(state: .waiting, sha: Self.head2, attempts: 1))
        #expect(try actions(tracker, [candidate(fixed)], at: minutes(29)).isEmpty)
        #expect(try actions(tracker, [candidate(fixed)], at: minutes(30)) == ["503:review"])
    }

    @Test func givesUpAfterThreeConsecutiveReviewsWithMustFixItems() throws {
        var tracker = FinalReviewTracker()
        var current = pullRequest()
        let heads = [Self.head1, Self.head2, Self.head3]
        for (index, head) in heads.enumerated() {
            current = pullRequest(head: head)
            tracker.update(with: [candidate(current, codeRabbit: .rateLimited)], now: start)
            tracker.start(.review, for: current)
            tracker.record(.reviewed(must: 1, may: 0), for: current)
            tracker.finish(current)
            if index < heads.count - 1 {
                tracker.start(.fix, for: current)
                tracker.record(.fixed(head: heads[index + 1]), for: current)
                tracker.finish(current)
            }
        }
        #expect(tracker.marker(for: current) == FinalReviewMarker(state: .gaveUp, sha: Self.head3, attempts: 3))
        #expect(try actions(tracker, [candidate(current, codeRabbit: .rateLimited)], at: minutes(60)).isEmpty)

        // 人が直して push すれば（自分の修正ではない head）、回数を 0 に戻してまた回る（Q1）
        let byHuman = pullRequest(head: String(repeating: "4", count: 40))
        tracker.update(with: [candidate(byHuman, codeRabbit: .rateLimited)], now: minutes(70))
        #expect(tracker.marker(for: byHuman) == FinalReviewMarker(state: .waiting, sha: byHuman.headSHA, attempts: 0))
        #expect(try actions(tracker, [candidate(byHuman, codeRabbit: .rateLimited)], at: minutes(70)) == ["503:review"])
    }

    @Test func headChangedByOthersRestartsWaitingAndResetsAttempts() throws {
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .rateLimited)], now: start)
        tracker.start(.review, for: pullRequest())
        tracker.record(.reviewed(must: 1, may: 0), for: pullRequest())
        tracker.finish(pullRequest())

        // コンフリクトの解消・develop の取り込みなどで head が変わった（Q3）。前の head のレビューは引き継がない
        let merged = pullRequest(head: Self.head3)
        tracker.update(with: [candidate(merged)], now: minutes(5))
        #expect(tracker.marker(for: merged) == FinalReviewMarker(state: .waiting, sha: Self.head3, attempts: 0))
        #expect(try actions(tracker, [candidate(merged)], at: minutes(14)).isEmpty)
        #expect(try actions(tracker, [candidate(merged)], at: minutes(15)) == ["503:review"])
    }

    @Test func stopsWhenCodeRabbitReviewsCurrentHead() throws {
        // レビュー中・修正中でも、CodeRabbit が今の head をレビューしたらやめる（Q2）
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .rateLimited)], now: start)
        tracker.start(.review, for: pullRequest())
        tracker.record(.reviewed(must: 1, may: 0), for: pullRequest())
        tracker.finish(pullRequest())

        let reviewed = [candidate(pullRequest(), codeRabbit: .completed)]
        tracker.update(with: reviewed, now: minutes(3))
        #expect(tracker.marker(for: pullRequest()) == FinalReviewMarker(state: .doneCodeRabbit, sha: Self.head1, attempts: 1))
        #expect(try actions(tracker, reviewed, at: minutes(30)).isEmpty)
    }

    @Test func cleanReviewOnGitHubMarksDone() throws {
        // 今の head の第三者レビューで要修正が 0 件なら（ループのレビューや再起動の前のレビュー）、済みにする
        var tracker = FinalReviewTracker()
        let clean = [candidate(pullRequest(), review: ThirdPartyReviewMarker(sha: Self.head1, must: 0, may: 1))]
        tracker.update(with: clean, now: start)
        #expect(tracker.marker(for: pullRequest())?.state == .done)
        #expect(try actions(tracker, clean, at: minutes(30)).isEmpty)
    }

    @Test func doesNotStartWhileConflictingOrBusy() throws {
        var tracker = FinalReviewTracker()
        let conflicting = [candidate(pullRequest(), codeRabbit: .rateLimited, isConflicting: true)]
        tracker.update(with: conflicting, now: start)
        #expect(try actions(tracker, conflicting, at: minutes(30)).isEmpty)

        // コンフリクトの解消を実行中のリポジトリも選ばない（同じ checkout に一時 worktree を作るため）
        let candidates = [candidate(pullRequest(), codeRabbit: .rateLimited)]
        tracker.update(with: candidates, now: start)
        #expect(try actions(tracker, candidates, at: start, busy: ["Shilokuma-Inc/Ask-Hub-Apple"]).isEmpty)
        #expect(try actions(tracker, candidates, at: start) == ["503:review"])
    }

    @Test func runsOnePullRequestPerRepositoryAtATime() throws {
        var tracker = FinalReviewTracker()
        let candidates = [
            candidate(pullRequest(number: 1), codeRabbit: .rateLimited),
            candidate(pullRequest(number: 2), codeRabbit: .rateLimited),
            candidate(pullRequest(repository: "shilokuma-inc/notti-ios", number: 3), codeRabbit: .rateLimited),
            // 担当外のリポジトリは扱わない
            candidate(pullRequest(repository: "shilokuma-inc/other", number: 4), codeRabbit: .rateLimited)
        ]
        tracker.update(with: candidates, now: start)
        #expect(try actions(tracker, candidates, at: start) == ["1:review", "3:review"])

        tracker.start(.review, for: pullRequest(number: 1))
        #expect(try actions(tracker, candidates, at: start) == ["3:review"])
        tracker.finish(pullRequest(number: 1))
        // 結果を記録せずに終えた（利用上限など）なら、待っている状態に戻って試し直す
        #expect(tracker.marker(for: pullRequest(number: 1))?.state == .waiting)
        #expect(try actions(tracker, candidates, at: start) == ["1:review", "3:review"])
    }

    @Test func givesUpAfterRepeatedCommandFailures() throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: .rateLimited)]
        tracker.update(with: candidates, now: start)
        for _ in 1..<FinalReviewTracker.maxFailures {
            tracker.record(FinalReviewTracker.ReviewOutcome.failed(reason: "x"), for: pullRequest())
            #expect(try actions(tracker, candidates, at: start) == ["503:review"])
        }
        tracker.record(FinalReviewTracker.ReviewOutcome.failed(reason: "x"), for: pullRequest())
        #expect(tracker.marker(for: pullRequest())?.state == .gaveUp)
        #expect(try actions(tracker, candidates, at: start).isEmpty)
    }

    @Test func ignoresResultsForOldHeadAndForgetsClosedPullRequests() throws {
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(head: Self.head2))], now: start)
        // 前の head のレビューの結果は使わない
        tracker.record(.reviewed(must: 0, may: 0), for: pullRequest(head: Self.head1))
        #expect(tracker.marker(for: pullRequest(head: Self.head2))?.state == .waiting)

        // マージ・クローズで一覧から消えた PR は追跡をやめる
        tracker.update(with: [], now: minutes(1))
        #expect(tracker.marker(for: pullRequest(head: Self.head2)) == nil)
    }

    @Test func keepsDoneCodeRabbitWhenLateResultsArrive() throws {
        // レビュー中に CodeRabbit が今の head をレビューした。後から届いた結果で上書きしない（Q2）
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .rateLimited)], now: start)
        tracker.start(.review, for: pullRequest())
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .completed)], now: minutes(2))
        let gaveUp1 = tracker.record(FinalReviewTracker.ReviewOutcome.reviewed(must: 2, may: 0), for: pullRequest())
        #expect(!gaveUp1)
        tracker.finish(pullRequest())
        #expect(tracker.marker(for: pullRequest()) == FinalReviewMarker(state: .doneCodeRabbit, sha: Self.head1))
        let gaveUp2 = tracker.record(FinalReviewTracker.FixOutcome.failed(reason: "x"), for: pullRequest())
        #expect(!gaveUp2)
        #expect(tracker.marker(for: pullRequest())?.state == .doneCodeRabbit)
    }

    @Test func doesNotFixWhenCodeRabbitCompletedAfterMustFixReview() throws {
        var tracker = FinalReviewTracker()
        tracker.update(with: [candidate(pullRequest(), codeRabbit: .rateLimited)], now: start)
        tracker.record(FinalReviewTracker.ReviewOutcome.reviewed(must: 1, may: 0), for: pullRequest())
        // 次の取得の前でも、CodeRabbit が完了した PR は直さない
        #expect(try actions(tracker, [candidate(pullRequest(), codeRabbit: .completed)], at: start).isEmpty)
    }

    @Test func retriesFixAndGivesUpAfterRepeatedFixFailures() throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: .rateLimited)]
        tracker.update(with: candidates, now: start)
        tracker.record(FinalReviewTracker.ReviewOutcome.reviewed(must: 1, may: 0), for: pullRequest())
        // 修正の失敗は修正をやり直す。今の head と同じ SHA を「直した」と返したときも失敗に数える
        let gaveUp3 = tracker.record(FinalReviewTracker.FixOutcome.failed(reason: "検証が通らない"), for: pullRequest())
        #expect(!gaveUp3)
        #expect(try actions(tracker, candidates, at: start) == ["503:fix"])
        let gaveUp4 = tracker.record(FinalReviewTracker.FixOutcome.fixed(head: Self.head1.uppercased()), for: pullRequest())
        #expect(!gaveUp4)
        #expect(try actions(tracker, candidates, at: start) == ["503:fix"])
        let gaveUp5 = tracker.record(FinalReviewTracker.FixOutcome.failed(reason: "x"), for: pullRequest())
        #expect(gaveUp5)
        #expect(tracker.marker(for: pullRequest())?.state == .gaveUp)
        #expect(try actions(tracker, candidates, at: start).isEmpty)
    }

    @Test func waitsForNewHeadAfterStaleResult() throws {
        var tracker = FinalReviewTracker()
        let candidates = [candidate(pullRequest(), codeRabbit: .rateLimited)]
        tracker.update(with: candidates, now: start)
        tracker.start(.review, for: pullRequest())
        tracker.record(FinalReviewTracker.ReviewOutcome.stale, for: pullRequest())
        tracker.finish(pullRequest())
        // GitHub の検索にまだ新しい head が出ていなくても、古い head のレビューを繰り返さない
        tracker.update(with: candidates, now: minutes(1))
        #expect(tracker.marker(for: pullRequest())?.state == .waiting)
        #expect(try actions(tracker, candidates, at: minutes(30)).isEmpty)
        // 新しい head が見えたら、また回る
        let moved = [candidate(pullRequest(head: Self.head2), codeRabbit: .rateLimited)]
        tracker.update(with: moved, now: minutes(2))
        #expect(try actions(tracker, moved, at: minutes(2)) == ["503:review"])

        // 修正の stale も同じ
        tracker.record(FinalReviewTracker.ReviewOutcome.reviewed(must: 1, may: 0), for: pullRequest(head: Self.head2))
        tracker.record(FinalReviewTracker.FixOutcome.stale, for: pullRequest(head: Self.head2))
        #expect(try actions(tracker, moved, at: minutes(3)).isEmpty)
    }

    @Test func ignoresCleanReviewOfAnotherHeadAndKeepsGaveUp() throws {
        var tracker = FinalReviewTracker()
        // 呼び出し側が誤って前の head のレビューを渡しても、済みにしない（Q3）
        let oldReview = ThirdPartyReviewMarker(sha: Self.head2, must: 0, may: 0)
        tracker.update(with: [candidate(pullRequest(head: Self.head1.uppercased()), review: oldReview)], now: start)
        #expect(tracker.marker(for: pullRequest())?.state == .waiting)
        // head の大文字小文字は区別しない
        #expect(tracker.marker(for: pullRequest())?.sha == Self.head1)

        // あきらめた後に要修正 0 件のレビューが付いても、あきらめたまま（人が push するまで）
        for _ in 0..<FinalReviewTracker.maxFailures {
            tracker.record(FinalReviewTracker.ReviewOutcome.failed(reason: "x"), for: pullRequest())
        }
        let clean = ThirdPartyReviewMarker(sha: Self.head1, must: 0, may: 0)
        tracker.update(with: [candidate(pullRequest(), review: clean)], now: minutes(1))
        #expect(tracker.marker(for: pullRequest())?.state == .gaveUp)
    }

    @Test func readsOutcomesFromLastResultLine() {
        let output = "ログ\nASKHUB_RESULT: reviewed\nASKHUB_RESULT: reviewed must=2 may=1\n"
        #expect(FinalReviewTracker.reviewOutcome(in: output) == .reviewed(must: 2, may: 1))
        #expect(FinalReviewTracker.reviewOutcome(in: "ASKHUB_RESULT: stale") == .stale)
        #expect(FinalReviewTracker.reviewOutcome(in: "ASKHUB_RESULT: failed 差分が空です") == .failed(reason: "差分が空です"))
        #expect(FinalReviewTracker.reviewOutcome(in: "ASKHUB_RESULT: failed") == .failed(reason: "理由は出力されませんでした"))
        #expect(FinalReviewTracker.reviewOutcome(in: "ASKHUB_RESULT: reviewed") == nil)
        #expect(FinalReviewTracker.reviewOutcome(in: "途中で落ちた") == nil)

        #expect(FinalReviewTracker.fixOutcome(in: "ASKHUB_RESULT: fixed \(Self.head2.uppercased())") == .fixed(head: Self.head2))
        #expect(FinalReviewTracker.fixOutcome(in: "ASKHUB_RESULT: stale") == .stale)
        #expect(FinalReviewTracker.fixOutcome(in: "ASKHUB_RESULT: failed 検証が通りません") == .failed(reason: "検証が通りません"))
        #expect(FinalReviewTracker.fixOutcome(in: "ASKHUB_RESULT: fixed abc1234") == nil)
    }
}
