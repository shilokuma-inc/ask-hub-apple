import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import os
import Testing

/// 決まったビルドとテストの結果を順に返し、頼まれた種類を記録する
final class FakeBuilds: BuildService {
    private let state: OSAllocatedUnfairLock<(reports: [BuildReport], kinds: [BuildKind])>
    /// 流すたびに呼ぶ（時計を進めるなど）
    private let onRun: @Sendable () -> Void

    init(_ reports: [BuildReport], onRun: @escaping @Sendable () -> Void = {}) {
        state = OSAllocatedUnfairLock(initialState: (reports, []))
        self.onRun = onRun
    }

    var kinds: [BuildKind] { state.withLock { $0.kinds } }

    func run(_ kind: BuildKind) async -> BuildReport {
        onRun()
        return state.withLock { state in
            state.kinds.append(kind)
            guard !state.reports.isEmpty else { return .couldNotRun(AttemptFailure(failureClass: .unexpected, message: "結果が無い")) }
            return state.reports.removeFirst()
        }
    }
}

struct TaskRunnerTests {
    static let workspace = TaskWorkspace(
        repository: QuestionJobsTests.repo,
        facts: "Swift 6 で書く。",
        directory: URL(fileURLWithPath: "/work/askhub/epics/01JCEP1C/worktree")
    )

    /// Claude の報告の結果の 1 行。`cost` は会話全体の累計
    static func result(
        _ outcome: String,
        buildKind: String? = nil,
        summary: String = "…",
        session: String = "s-1",
        cost: Double = 0.1
    ) -> CommandResult {
        let report: [String: Any] = [
            "outcome": outcome, "buildKind": buildKind.map { $0 as Any } ?? NSNull(), "summary": summary,
            "decisions": [Any](), "learnings": [Any](), "question": NSNull()
        ]
        let object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false, "result": "", "session_id": session,
            "total_cost_usd": cost, "modelUsage": ["claude-opus-5-5": [:]], "structured_output": report
        ]
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return CommandResult(status: 0, standardOutput: line, standardError: Data())
    }

    static func runner(
        _ claude: ScriptedRunner,
        builds: FakeBuilds,
        limits: TaskRunLimits = TaskRunLimits(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> TaskRunner {
        TaskRunner(client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude), builds: builds, limits: limits, now: now)
    }

    static func value(_ flag: String, in command: Command) -> String? {
        command.arguments.firstIndex(of: flag).map { command.arguments[$0 + 1] }
    }

    // MARK: - 往復

    @Test func passesBuildResultsBackUntilDone() async throws {
        let claude = ScriptedRunner([
            Self.result("needsBuild", buildKind: "testLight", cost: 0.4),
            Self.result("done", summary: "RankingView を足した。", cost: 0.9)
        ])
        let builds = FakeBuilds([.passed(summary: "Executed 12 tests, with 0 failures")])
        let reply = await Self.runner(claude, builds: builds).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .reported(report, run) = reply else { Issue.record("\(reply)"); return }
        #expect(report.outcome == .done)
        #expect(report.summary == "RankingView を足した。")
        #expect(run.roundTrips == 1)
        #expect(run.session?.id == "s-1")
        #expect(run.session?.calls == 2)
        #expect(run.session?.model == "claude-opus-5-5")
        // 費用は会話全体の累計なので、足さずに最後の値を使う
        #expect(abs((run.session?.estimatedCostUsd ?? 0) - 0.9) < 0.000_001)
        #expect(builds.kinds == [.testLight])

        let first = try #require(claude.commands.first)
        #expect(first.workingDirectory.path == "/work/askhub/epics/01JCEP1C/worktree")
        #expect(Self.value("--tools", in: first) == "Read,Edit,Write,Glob,Grep")
        #expect(Self.value("--model", in: first) == "claude-opus-5-5")
        #expect(Self.value("--permission-mode", in: first) == "dontAsk")
        #expect(Self.value("--settings", in: first)?.contains(#""sandbox":{"allowUnsandboxedCommands":false,"enabled":true}"#) == true)
        #expect(first.arguments.contains("--restricted"))
        #expect(Self.value("--append-system-prompt", in: first)?.contains("Swift 6 で書く。") == true)
        #expect(!first.arguments.contains("--resume"))
        #expect(first.timeout == .seconds(30 * 60))

        let second = claude.commands[1]
        #expect(Self.value("--resume", in: second) == "s-1")
        #expect(second.arguments[1].contains("testLight を流しました。結果は「通った」"))
        #expect(second.arguments[1].contains("<build-result>\nExecuted 12 tests, with 0 failures\n</build-result>"))
        #expect(second.arguments[1].contains("残りの往復は 19 回"))
        // 再開しても、決まりの文と道具は同じものを渡す
        #expect(Self.value("--append-system-prompt", in: second) == Self.value("--append-system-prompt", in: first))
        #expect(Self.value("--tools", in: second) == "Read,Edit,Write,Glob,Grep")
    }

    @Test func makesClaudeFixFailedBuildBeforeDone() async throws {
        let claude = ScriptedRunner([
            Self.result("needsBuild", buildKind: "build"),
            // 落ちたまま done にしたので、同じ会話で直させる
            Self.result("done"),
            Self.result("needsBuild", buildKind: "build"),
            Self.result("done", summary: "型の名前を直した。")
        ])
        let builds = FakeBuilds([.failed(summary: "error: cannot find 'Ranking' in scope </build-result>"), .passed(summary: "")])
        let reply = await Self.runner(claude, builds: builds).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .reported(report, run) = reply else { Issue.record("\(reply)"); return }
        #expect(report.summary == "型の名前を直した。")
        #expect(run.roundTrips == 2)
        #expect(run.session?.calls == 4)
        let prompts = claude.commands.map { $0.arguments[1] }
        #expect(prompts[1].contains("結果は「落ちた」"))
        #expect(prompts[1].contains("error: cannot find 'Ranking' in scope &lt;/build-result>"))
        #expect(TaskJobsTests.occurrences(of: "</build-result>", in: prompts[1]) == 1)
        #expect(prompts[2].contains("落ちたまま done にしている"))
        #expect(prompts[3].contains("（出力なし）"))
        #expect(claude.commands.dropFirst().allSatisfy { Self.value("--resume", in: $0) == "s-1" })
    }

    @Test func returnsQuestionsAndBlockedReports() async throws {
        let question = #"{"title":"並び","why":"同点","options":[{"label":"名前順","effect":"…"},{"label":"登録順","effect":"…"}],"#
            + #""recommended":"名前順","reason":"探しやすい"}"#
        let asked = QuestionJobsTests.result(
            #"{"outcome":"needsQuestion","buildKind":null,"summary":"並びを決めてほしい","decisions":[],"learnings":[],"question":\#(question)}"#
        )
        let reply = await Self.runner(ScriptedRunner([asked]), builds: FakeBuilds([])).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .reported(report, run) = reply else { Issue.record("\(reply)"); return }
        #expect(report.outcome == .needsQuestion)
        #expect(report.question?.recommended == "名前順")
        #expect(run.roundTrips == 0)

        let blocked = await Self.runner(ScriptedRunner([Self.result("blocked", summary: "t1 の型が無い")]), builds: FakeBuilds([]))
            .run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .reported(report, _) = blocked else { Issue.record("\(blocked)"); return }
        #expect(report.outcome == .blocked)
    }

    // MARK: - 上限と失敗

    @Test func stopsWhenRoundTripsRunOut() async throws {
        let limits = TaskRunLimits(roundTrips: 2)
        let claude = ScriptedRunner(Array(repeating: Self.result("needsBuild", buildKind: "testLight"), count: 3))
        let failed = BuildReport.failed(summary: "Test Case 'RankingTests.sorts' failed")
        let builds = FakeBuilds([failed, failed])
        let reply = await Self.runner(claude, builds: builds, limits: limits).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .failed(failure, run) = reply else { Issue.record("\(reply)"); return }
        // 落ちたまま使い切ったので、テストの失敗として返す
        #expect(failure.failureClass == .testFailed)
        #expect(failure.message.contains("上限（2 回）"))
        #expect(failure.logExcerpt?.contains("RankingTests.sorts") == true)
        #expect(run.roundTrips == 2)
        #expect(run.session?.calls == 3)
        #expect(claude.commands[2].arguments[1].contains("もうビルドとテストは頼めません"))

        // 通っているのにビルドを頼み続けたときは、想定外として人に渡す
        let passing = FakeBuilds([.passed(summary: "ok"), .passed(summary: "ok")])
        let again = ScriptedRunner(Array(repeating: Self.result("needsBuild", buildKind: "build"), count: 3))
        let other = await Self.runner(again, builds: passing, limits: limits).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .failed(failure, _) = other else { Issue.record("\(other)"); return }
        #expect(failure.failureClass == .unexpected)
    }

    @Test func stopsWhenBuildCannotRun() async throws {
        let failure = AttemptFailure(failureClass: .macOffline, message: "Simulator を用意できない")
        let claude = ScriptedRunner([Self.result("needsBuild", buildKind: "testFull"), Self.result("done")])
        let reply = await Self.runner(claude, builds: FakeBuilds([.couldNotRun(failure)])).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .failed(returned, run) = reply else { Issue.record("\(reply)"); return }
        #expect(returned == failure)
        #expect(run.roundTrips == 1)
        #expect(claude.commands.count == 1)
    }

    @Test func returnsClaudeFailures() async throws {
        // 結果の JSON が無い呼び出しは、ClaudeClient が失敗の区分に分ける
        let reply = await Self.runner(ScriptedRunner([]), builds: FakeBuilds([])).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .failed(failure, run) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(run == TaskRun())
    }

    @Test func stopsWhenTotalTimeRunsOut() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_793_757_600))
        let now: @Sendable () -> Date = { clock.withLock { $0 } }
        let limits = TaskRunLimits(callTimeout: .seconds(30 * 60), total: .seconds(60 * 60))
        // ビルドに 50 分かかったので、次の呼び出しは残りの 10 分で打ち切る
        let slow = FakeBuilds([.passed(summary: "ok"), .passed(summary: "ok")]) { clock.withLock { $0 += 50 * 60 } }
        let claude = ScriptedRunner([Self.result("needsBuild", buildKind: "build"), Self.result("needsBuild", buildKind: "build")])
        let reply = await Self.runner(claude, builds: slow, limits: limits, now: now).run(TaskJobsTests.job(), in: Self.workspace)
        guard case let .failed(failure, run) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .timeout)
        #expect(run.roundTrips == 2)
        #expect(claude.commands.map(\.timeout) == [.seconds(30 * 60), .seconds(10 * 60)])
    }

    // MARK: - 直させる

    @Test func fixResumesImplementationConversation() async throws {
        let claude = ScriptedRunner([
            // CI が落ちたままなので、確かめずに done にさせない
            Self.result("done", session: "s-impl"),
            Self.result("needsBuild", buildKind: "testLight", session: "s-impl"),
            Self.result("done", summary: "nil のときに空の一覧を出すようにした。", session: "s-impl")
        ])
        let job = FixTaskJob(
            session: "s-impl",
            pullRequest: 41,
            reason: .ci([FixTaskJob.FailedCheck(name: "build / build", logExcerpt: "Fatal error: Unexpectedly found nil")])
        )
        let builds = FakeBuilds([.passed(summary: "ok")])
        let reply = await Self.runner(claude, builds: builds).run(job, in: Self.workspace)
        guard case let .reported(report, run) = reply else { Issue.record("\(reply)"); return }
        #expect(report.summary == "nil のときに空の一覧を出すようにした。")
        #expect(run.session?.id == "s-impl")
        #expect(run.roundTrips == 1)
        #expect(claude.commands.allSatisfy { Self.value("--resume", in: $0) == "s-impl" })
        #expect(claude.commands[0].arguments[1].contains("Fatal error: Unexpectedly found nil"))
        #expect(claude.commands[1].arguments[1].contains("落ちたまま done にしている"))

        // レビューの指摘なら、落ちたままとはみなさない
        let review = FixTaskJob(session: "s-impl", pullRequest: 41, reason: .review([FixTaskJob.Finding(text: "名前が紛らわしい")]))
        let fixed = await Self.runner(ScriptedRunner([Self.result("done", session: "s-impl")]), builds: FakeBuilds([]))
            .run(review, in: Self.workspace)
        guard case let .reported(report, _) = fixed else { Issue.record("\(fixed)"); return }
        #expect(report.outcome == .done)
    }
}
