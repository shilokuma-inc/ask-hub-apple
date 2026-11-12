@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 待つチェックが出ないとき、GitHub Actions の実行が止まっているかを見分けて PR を開き直す（`ReviewTaskRunner+StalledRuns.swift`）
struct StalledRunsTests {
    typealias Fixture = TaskJobFixture
    static let missing = CheckSummary(verdict: .pending, missing: ["build / build"])
    static let minute: TimeInterval = 60
    static let noFindings = ReviewTaskRunnerTests.noFindings

    /// GitHub Actions の実行。`minutes` は待ち始め（`Fixture.start`）から何分後に始まったか（負なら前）
    static func run(_ id: Int, event: String = "push", status: String = "queued", minutes: Double = -14 * 60) -> WorkflowRun {
        WorkflowRun(id: id, name: "Build", event: event, status: status, startedAt: Fixture.start.addingTimeInterval(minutes * minute))
    }

    /// 子 PR #41 を置き、チェックの様子（読むたびに先頭から）と実行の一覧（読むたびに先頭から）を決める
    func fixture(
        checks: [CheckSummary],
        runs: [[WorkflowRun]],
        jobs: [Int: Int] = [:],
        reviews: [CommandResult] = []
    ) async throws -> Fixture {
        let fixture = try await ReviewTaskRunnerTests().fixture(reviews: reviews, checks: checks)
        fixture.pulls.update { state in
            state.workflowRuns = runs
            state.jobCounts = jobs
        }
        return fixture
    }

    func review(_ fixture: Fixture) async throws -> JobResult {
        try await ReviewTaskRunnerTests().review(fixture)
    }

    // MARK: - 開き直す

    @Test func reopensPullRequestWhenRunIsStuckAndMergesOnceChecksPass() async throws {
        // 2026-11-12 の BeaconFun4/demomoni-remake-ios#172: push と pull_request の実行が、queued のままジョブが 0 個で 14 時間止まった
        let ghosts = [Self.run(100), Self.run(101, event: "pull_request")]
        let checks = Array(repeating: Self.missing, count: 11) + [CheckSummary(verdict: .passed)]
        let fixture = try await fixture(checks: checks, runs: [ghosts], jobs: [100: 0, 101: 0], reviews: [Self.noFindings])
        let result = try await review(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.verdict == .merged)
        // 出ないまま 10 分たったら実行を読み、閉じてすぐ開き直す。開き直した PR をそのままマージする
        let changes = fixture.pulls.current.stateChanges
        #expect(changes.map(\.number) == [41, 41])
        #expect(changes.map(\.state) == [.closed, .open])
        #expect(fixture.pulls.current.merges.map(\.head) == [ReviewTaskRunnerTests.head])
        #expect(fixture.pulls.current.workflowRunReads == 1)
        #expect(fixture.sleeper.waits == Array(repeating: .seconds(60), count: 11))
    }

    @Test func retriesReopeningSoPullRequestIsNotLeftClosed() async throws {
        let checks = Array(repeating: Self.missing, count: 11) + [CheckSummary(verdict: .passed)]
        let fixture = try await fixture(checks: checks, runs: [[Self.run(100)]], jobs: [100: 0], reviews: [Self.noFindings])
        fixture.pulls.update { $0.reopenFailures = [.serverError(status: 502), .serverError(status: 502)] }
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .merged)
        #expect(fixture.pulls.current.stateChanges.map(\.state) == [.closed, .open])
        #expect(fixture.sleeper.waits.filter { $0 == ReviewTaskRunner.reopenRetryWait }.count == 2)
    }

    @Test func handsOverWhenPullRequestCannotBeReopened() async throws {
        let fixture = try await fixture(checks: [Self.missing], runs: [[Self.run(100)]], jobs: [100: 0])
        fixture.pulls.update { $0.reopenFailures = Array(repeating: .serverError(status: 502), count: 3) }
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("子 PR #41 を閉じたが、開き直せない") == true)
        #expect(fixture.pulls.current.stateChanges.map(\.state) == [.closed])
    }

    // MARK: - 開き直しても始まらない

    @Test func failsAsGitHubOutageWhenNewRunAlsoStalls() async throws {
        // 開き直した（10 分後）ときにできた新しい実行も、queued のままジョブが 0 個
        let after = [Self.run(100), Self.run(102, event: "pull_request", minutes: 10)]
        let fixture = try await fixture(checks: [Self.missing], runs: [[Self.run(100)], after], jobs: [100: 0, 102: 0])
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .githubOutage)
        #expect(result.failure?.message.contains("PR を閉じて開き直した後も queued のままジョブが 0 個で止まっている") == true)
        #expect(result.failure?.message.contains("repo.json") == false)
        // 開き直すのは 1 回だけ。開き直してから 10 分後に諦める
        #expect(fixture.pulls.current.stateChanges.map(\.state) == [.closed, .open])
        #expect(fixture.sleeper.waits == Array(repeating: .seconds(60), count: 20))
    }

    @Test func handsOverWhenReopeningCreatesNoRun() async throws {
        let fixture = try await fixture(checks: [Self.missing], runs: [[Self.run(100)]], jobs: [100: 0])
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("開き直しても新しい実行が作られない") == true)
        #expect(result.failure?.message.contains("repo.json") == false)
        #expect(fixture.pulls.current.stateChanges.map(\.state) == [.closed, .open])
    }

    @Test func handsOverWhenNewRunNeverShowsRequiredChecks() async throws {
        // 開き直した後の実行は動いた（PR のイベントでは待つチェックのジョブを飛ばすなど）が、待つチェックは出ない
        let after = [Self.run(100), Self.run(102, event: "pull_request", status: "completed", minutes: 10)]
        let fixture = try await fixture(checks: [Self.missing], runs: [[Self.run(100)], after], jobs: [100: 0])
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("その後の実行（Build・pull_request）でも") == true)
        #expect(fixture.pulls.current.stateChanges.count == 2)
        // 開き直してから 30 分待つ
        #expect(fixture.sleeper.waits.count == 40)
    }

    // MARK: - 止まっていない

    @Test func explainsSettingsWhenRunsExistButRequiredChecksDoNot() async throws {
        let runs = [Self.run(100, status: "completed"), Self.run(101, event: "pull_request", minutes: -20)]
        // queued でもジョブがある実行は止まっていない（ランナーを待つジョブは、チェックとして出る）
        let fixture = try await fixture(checks: [Self.missing], runs: [runs], jobs: [101: 2])
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        let message = try #require(result.failure?.message)
        #expect(message.contains("子 PRのチェック（build / build）が"))
        #expect(message.contains("head の GitHub Actions の実行（Build・push、Build・pull_request）はあるが、待つチェックが出ない"))
        #expect(message.contains("build.childChecks"))
        #expect(fixture.pulls.current.stateChanges.isEmpty)
        // 実行の一覧は、出ないまま 10 分ごと（10・20・30 分）にだけ読む
        #expect(fixture.pulls.current.workflowRunReads == 3)
        #expect(fixture.sleeper.waits == Array(repeating: .seconds(60), count: 30))
    }

    @Test func doesNotReadRunsWhileChecksAreRunning() async throws {
        let running = CheckSummary(verdict: .pending, unfinished: ["build / build"])
        let checks = Array(repeating: running, count: 40) + [CheckSummary(verdict: .passed)]
        let fixture = try await fixture(checks: checks, runs: [[Self.run(100)]], jobs: [100: 0], reviews: [Self.noFindings])
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .merged)
        #expect(fixture.pulls.current.workflowRunReads == 0)
        #expect(fixture.pulls.current.stateChanges.isEmpty)
    }

    @Test func suspectsOnlyLongQueuedRunsAndOnlyNewOnesAfterReopening() {
        let timing = ReviewTiming()
        let now = Fixture.start
        let runs = [
            Self.run(1, minutes: -11),
            Self.run(2, minutes: -9),
            Self.run(3, status: "in_progress", minutes: -60),
            Self.run(4, status: "pending", minutes: -60),
            WorkflowRun(id: 5, name: "Build", event: "push", status: "queued", startedAt: nil),
            Self.run(6, minutes: -30)
        ]
        var state = CheckWaitState()
        #expect(ReviewTaskRunner.suspects(runs, state: state, timing: timing, now: now).map(\.id) == [1, 6])
        state.reopenedAt = now
        state.newestRunBeforeReopen = 5
        #expect(ReviewTaskRunner.suspects(runs, state: state, timing: timing, now: now).map(\.id) == [6])
    }

    // MARK: - 最終 PR

    @Test func reopensFinalPullRequestToo() async throws {
        let checks = Array(repeating: Self.missing, count: 11) + [CheckSummary(verdict: .passed)]
        let tests = ReviewFinalPullRequestRunnerTests()
        let fixture = try await tests.fixture(checks: checks)
        fixture.pulls.update { state in
            state.workflowRuns = [[Self.run(100, event: "pull_request")]]
            state.jobCounts = [100: 0]
        }
        let result = try await tests.review(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.verdict == .ready)
        #expect(fixture.pulls.current.stateChanges.map(\.number) == [512, 512])
        #expect(fixture.pulls.current.stateChanges.map(\.state) == [.closed, .open])
    }
}
