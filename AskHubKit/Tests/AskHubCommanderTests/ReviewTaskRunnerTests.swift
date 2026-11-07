@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

struct ReviewTaskRunnerTests {
    typealias Fixture = TaskJobFixture
    static let head = sha("1")
    static let input = PullRequestInput(pullRequest: 41, head: head)
    static let noFindings = QuestionJobsTests.result(#"{"required":[],"summary":"問題なし"}"#)

    static func failed(job: Int, run: Int = 7) -> CheckSummary {
        let failure = FailedCheck(name: "build / build", source: .checkRun, conclusion: "failure", runID: run, jobID: job)
        return CheckSummary(verdict: .failed, failures: [failure])
    }

    /// 子ブランチから作業ブランチへの開いた子 PR を置く
    func fixture(reviews: [CommandResult] = [], checks: [CheckSummary], head: String = Self.head) async throws -> Fixture {
        let fixture = Fixture(reviews: reviews)
        try await fixture.prepare()
        fixture.pulls.update { state in
            state.pulls[41] = Fixture.openPull(head: head)
            state.checks = checks
        }
        return fixture
    }

    func review(_ fixture: Fixture) async throws -> JobResult {
        let runner = ReviewTaskRunner(environment: try fixture.environment(FakeTaskRunner([])))
        return try await runner.execute(fixture.job(.reviewTask, "03", input: Self.input.jobInput))
    }

    @Test func mergesPinnedHeadWhenChecksPassAndReviewerFindsNothing() async throws {
        let pending = CheckSummary(verdict: .pending, unfinished: ["build / build"])
        let fixture = try await fixture(reviews: [Self.noFindings], checks: [pending, CheckSummary(verdict: .passed)])
        let result = try await review(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.verdict == .merged)
        #expect(result.outputs?.commit == String(repeating: "e", count: 40))
        #expect(result.outputs?.pullRequest == 41)
        #expect(result.claude?.model == "claude-opus-5-5")
        // 見た head を固定してマージし、子ブランチを消す
        #expect(fixture.pulls.current.merges.map(\.head) == [Self.head])
        #expect(fixture.pulls.current.deletions.map(\.branch) == [Fixture.branches.task])
        #expect(fixture.pulls.current.deletions.map(\.expected) == [Self.head])
        // 待つのは repo.json の build.childChecks
        #expect(fixture.pulls.current.policies.first?.required == ["build / build"])
        #expect(fixture.sleeper.waits == [.seconds(60)])

        // レビュー役は読むだけの Claude（Opus 5.5）で、子 PR の head の作業場所で差分を読む
        let command = try #require(fixture.reviewer.commands.first)
        #expect(TaskRunnerTests.value("--model", in: command) == "claude-opus-5-5")
        #expect(TaskRunnerTests.value("--tools", in: command) == "Read,Grep,Glob")
        #expect(command.workingDirectory == FakeTaskGit.directory)
        #expect(command.arguments[1].contains("+struct Ranking {}"))
        #expect(command.arguments[1].contains("ランキングの画面を作る"))
        #expect(TaskRunnerTests.value("--append-system-prompt", in: command)?.contains("Swift 6 で書く。") == true)
        #expect(fixture.git.current.calls == ["checkOutReview \(Self.head)"])
    }

    @Test func rerunsFirstFailureOnceAndMergesWhenItPasses() async throws {
        // 流し直した後、新しい実行が出てくるまでは古い失敗（同じ job）が返る
        let pending = CheckSummary(verdict: .pending, unfinished: ["build / build"])
        let checks = [Self.failed(job: 70), Self.failed(job: 70), pending, .init(verdict: .passed)]
        let fixture = try await fixture(reviews: [Self.noFindings], checks: checks)
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .merged)
        #expect(fixture.pulls.current.reruns == [7])
    }

    @Test func secondFailureBecomesFixCIWithRedactedLogExcerpt() async throws {
        let fixture = try await fixture(checks: [Self.failed(job: 70), Self.failed(job: 71)])
        fixture.pulls.update { state in
            state.logs[71] = "2026-11-07T09:00:00.1234567Z Compiling\n2026-11-07T09:00:01.0000000Z error: cannot find 'Ranking' in scope "
                + "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        }
        let result = try await review(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.verdict == .fixCI)
        #expect(result.outputs?.commit == Self.head)
        let findings = try #require(result.outputs?.findings)
        #expect(findings.hasPrefix("チェック: build / build（failure）\nCompiling\nerror: cannot find 'Ranking' in scope"))
        #expect(!findings.contains("ghp_"))
        #expect(!findings.contains("2026-11-07T"))
        // 流し直しは 1 回だけ。レビュー役は呼ばず、マージしない
        #expect(fixture.pulls.current.reruns == [7])
        #expect(fixture.reviewer.commands.isEmpty)
        #expect(fixture.pulls.current.merges.isEmpty)
    }

    @Test func doesNotWaitForStarvedChecksOnceSomethingFailed() async throws {
        // 落ちたチェックがあり、残りはランナー不足で始まらない。始まるのを待たずに流し直し、それでも落ちたら直させる
        var first = Self.failed(job: 70)
        first.unfinished = ["test / test"]
        first.starved = ["test / test"]
        var second = Self.failed(job: 71)
        second.unfinished = ["test / test"]
        second.starved = ["test / test"]
        let fixture = try await fixture(checks: [first, second])
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .fixCI)
        #expect(fixture.pulls.current.reruns == [7])
        #expect(fixture.sleeper.waits == [.seconds(60)])
    }

    @Test func failureThatCannotBeRerunGoesStraightToFixCI() async throws {
        let status = CheckSummary(verdict: .failed, failures: [FailedCheck(name: "lint", source: .commitStatus, conclusion: "error")])
        let fixture = try await fixture(checks: [status])
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .fixCI)
        #expect(result.outputs?.findings?.contains("（ログを読めなかった。詳細: なし）") == true)
        #expect(fixture.pulls.current.reruns.isEmpty)
    }

    @Test func keepsWaitingThroughRunnerShortage() async throws {
        let shortage = CheckSummary(verdict: .runnerShortage, unfinished: ["build / build"], starved: ["build / build"])
        let fixture = try await fixture(reviews: [Self.noFindings], checks: [shortage, shortage, shortage, .init(verdict: .passed)])
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .merged)
        #expect(fixture.sleeper.waits == [.seconds(600), .seconds(1_200), .seconds(2_400)])
    }

    @Test func requiredFindingsBecomeFixReview() async throws {
        let found = QuestionJobsTests.result(
            #"{"required":[{"path":"App/RankingView.swift","line":12,"text":"nil のときに落ちる"}],"summary":"直すところがある"}"#
        )
        let fixture = try await fixture(reviews: [found], checks: [.init(verdict: .passed)])
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .fixReview)
        #expect(result.outputs?.findings == "1. App/RankingView.swift:12\nnil のときに落ちる")
        #expect(result.claude?.session == "s-1")
        #expect(fixture.pulls.current.merges.isEmpty)
    }

    @Test func refusesHeadMovedSinceJobWasMade() async throws {
        let fixture = try await fixture(reviews: [Self.noFindings], checks: [.init(verdict: .passed)], head: sha("2"))
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("動いた") == true)
        #expect(fixture.pulls.current.merges.isEmpty)
        #expect(fixture.reviewer.commands.isEmpty)
    }

    @Test func finishesMergeOfPreviousAttempt() async throws {
        // 前の試行がマージした後、記録する前に落ちた
        let fixture = try await fixture(checks: [.init(verdict: .passed)])
        fixture.pulls.update { state in
            state.pulls[41]?.state = .closed
            state.pulls[41]?.merged = true
            state.pulls[41]?.mergeCommitSHA = String(repeating: "f", count: 40)
            state.deleteError = .headChanged
        }
        let result = try await review(fixture)
        #expect(result.outputs?.verdict == .merged)
        #expect(result.outputs?.commit == String(repeating: "f", count: 40))
        #expect(fixture.pulls.current.merges.isEmpty)
        #expect(fixture.reviewer.commands.isEmpty)
    }

    @Test func givesUpWhenRequiredChecksNeverStart() async throws {
        let fixture = try await fixture(checks: [CheckSummary(verdict: .pending, missing: ["build / build"])])
        let result = try await review(fixture)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("build.childChecks") == true)
        // 30 分（1 分ごとに 30 回）待ってから諦める
        #expect(fixture.sleeper.waits == Array(repeating: .seconds(60), count: 30))
    }
}
