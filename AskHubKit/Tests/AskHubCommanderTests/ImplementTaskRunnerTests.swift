@testable import AskHubClaude
@testable import AskHubCommander
import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

struct ImplementTaskRunnerTests {
    typealias Fixture = TaskJobFixture

    /// Claude が作業場所を書き換えたことにする実行
    static func editing(_ git: FakeTaskGit, _ replies: [TaskReply]) -> FakeTaskRunner {
        FakeTaskRunner(replies) { git.update { $0.dirty = true } }
    }

    @Test func implementsCommitsAndOpensChildPullRequest() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        // 前のタスク t1 の実装の報告
        let previous = AttemptFile.Outputs(report: TaskOutputReport(summary: "RankingClient を足した。"))
        try await fixture.record(fixture.job(.implementTask, "01", task: "t1"), outputs: previous)
        let fixed = AttemptFile.Outputs(report: TaskOutputReport(summary: "取得に失敗したら空の一覧を返すようにした。"))
        try await fixture.record(fixture.job(.fixTask, "03", task: "t1"), outputs: fixed, endedAt: 60)
        let decision = TaskReport.Decision(what: "行の高さを 44pt にした", why: "タップしやすい", alternatives: ["56pt"])
        let summary = "RankingView を足した。ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let runner = Self.editing(fixture.git, [FakeTaskRunner.done(summary, decisions: [decision])])
        let job = fixture.job(.implementTask, "02")
        try await fixture.files.create(job, at: StatePath.job(Fixture.repo, epic: Fixture.epic, job: job.id), message: "job")

        // 試行は JobWorker が書く（書いた試行が状態リポジトリの決まりに合うことも確かめる）
        let worker = JobWorker(
            runner: ImplementTaskRunner(environment: try fixture.environment(runner)),
            recorder: AttemptRecorder(files: fixture.context.files, mac: Fixture.mac) { fixture.sleeper.now }
        )
        let attempt = try #require(try await worker.perform(job))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.outputs?.pullRequest == 41)
        #expect(attempt.outputs?.commit == sha("1"))
        #expect(attempt.outputs?.branch == Fixture.branches.task)
        // 報告は、トークンらしい文字列を伏せてから書く
        #expect(attempt.outputs?.report?.summary == "RankingView を足した。<伏せた>")
        #expect(attempt.outputs?.report?.decisions.first?.alternatives == ["56pt"])
        #expect(attempt.claude == AttemptFile.Claude(model: "claude-opus-5-5", session: "s-impl", estimatedCostUsd: 0.4))

        // 子 PR は作業ブランチ宛て
        let draft = try #require(fixture.pulls.current.drafts.first)
        #expect(draft.base == Fixture.branches.epic)
        #expect(draft.head == Fixture.branches.task)
        #expect(draft.title == "ランキングの画面を作る")
        #expect(draft.body.contains("RankingView を足した。"))
        #expect(!draft.body.contains("ghp_"))
        #expect(fixture.git.current.commits.allSatisfy { !$0.contains("ghp_") })
        #expect(draft.body.contains("行の高さを 44pt にした: タップしやすい（ほかの案: 56pt）"))
        #expect(fixture.git.current.commits.first?.hasPrefix("ランキングの画面を作る\n\nRankingView を足した。") == true)

        // Claude には、前のタスクの要約と base のリポジトリの事実を渡し、epic の作業場所と枠でビルドさせる
        let call = try #require(runner.calls.first)
        #expect(call.kind == .implementTask)
        #expect(call.resume == nil)
        // 前のタスクの要約には、直しで変えたことも続けて渡す
        #expect(call.prompt.contains("要約: RankingClient を足した。\n直し: 取得に失敗したら空の一覧を返すようにした。"))
        #expect(call.facts == "Swift 6 で書く。")
        #expect(call.directory == FakeTaskGit.directory)
        #expect(runner.targets.map(\.slot) == [0])
        #expect(runner.targets.first?.epic == Fixture.epic)
        #expect(runner.targets.first?.settings.scheme == "App")
    }

    @Test func retryReusesPushedBranchAndOpenPullRequest() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let job = fixture.job(.implementTask, "02")
        let first = try await ImplementTaskRunner(environment: try fixture.environment(Self.editing(fixture.git, [FakeTaskRunner.done()])))
            .execute(job)
        #expect(first.outputs?.pullRequest == 41)

        // push と子 PR の後、記録する前に落ちたやり直し。子ブランチはリモートのものから続け、Claude は変えずに done と報告する
        let runner = FakeTaskRunner([FakeTaskRunner.done("もう実装してあった。")])
        let retry = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)
        #expect(retry.failure == nil)
        #expect(retry.outputs?.pullRequest == 41)
        #expect(retry.outputs?.commit == sha("1"))
        // 二重に PR を作らない・コミットを重ねない
        #expect(fixture.pulls.current.drafts.count == 1)
        #expect(fixture.git.current.commits.count == 1)
    }

    @Test func doneWithoutAnyChangeFails() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let result = try await ImplementTaskRunner(environment: try fixture.environment(FakeTaskRunner([FakeTaskRunner.done()])))
            .execute(fixture.job(.implementTask, "02"))
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message.contains("変更が無い") == true)
        // 報告と会話は残す（人が見る）
        #expect(result.outputs?.report?.summary == "RankingClient を足した。")
        #expect(result.claude?.session == "s-impl")
        #expect(fixture.pulls.current.drafts.isEmpty)
    }

    @Test func blockedAndExhaustedRoundTripsGoToHuman() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let session = ClaudeSession(id: "s-impl", model: "claude-opus-5-5", estimatedCostUsd: 0.2, calls: 1)
        let replies: [TaskReply] = [
            .reported(TaskReport(outcome: .blocked, summary: "素材の画像が無い"), TaskRun(session: session)),
            .failed(
                AttemptFailure(
                    failureClass: .testFailed,
                    message: "往復の上限を使い切った",
                    logExcerpt: "Test failed ghp_abcdefghijklmnopqrstuvwxyz0123456789"
                ),
                TaskRun(session: session)
            )
        ]
        let runner = Self.editing(fixture.git, replies)
        let implement = ImplementTaskRunner(environment: try fixture.environment(runner))
        let job = fixture.job(.implementTask, "02")

        // 人に聞きたいこと（needsQuestion）は、質問で成功として終える（`TaskQuestionRunnerTests`）
        let blocked = try await implement.execute(job)
        #expect(blocked.failure?.failureClass == .unexpected)
        #expect(blocked.failure?.message.contains("素材の画像が無い") == true)

        // 往復の使い切りは、Claude に直させずに人へ渡す。説明とログの抜粋は伏せてから書く
        let exhausted = try await implement.execute(job)
        #expect(exhausted.failure?.failureClass == .unexpected)
        #expect(exhausted.failure?.logExcerpt == "Test failed <伏せた>")
        #expect(exhausted.claude?.session == "s-impl")

        #expect(fixture.git.current.commits.isEmpty)
        #expect(fixture.pulls.current.drafts.isEmpty)
    }

    @Test func skipsEpicNotRunningAndRequiresBuildSettings() async throws {
        let stopped = Fixture()
        try await stopped.prepare(stage: .abandoned)
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let skipped = try await ImplementTaskRunner(environment: try stopped.environment(runner)).execute(stopped.job(.implementTask, "02"))
        #expect(skipped == JobResult())
        #expect(runner.calls.isEmpty)

        let fixture = Fixture()
        try await fixture.prepare()
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner, withoutSettings: true))
            .execute(fixture.job(.implementTask, "02"))
        #expect(result.failure?.message.contains("build") == true)
        #expect(runner.calls.isEmpty)

        let wrongKind = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(fixture.job(.fixTask, "03"))
        #expect(wrongKind.failure?.failureClass == .unexpected)
    }
}
