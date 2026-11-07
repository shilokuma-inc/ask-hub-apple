@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

struct FixTaskRunnerTests {
    typealias Fixture = TaskJobFixture
    /// 直す head（直した後の head は偽の git が作る sha("1")）
    static let head = sha("5")
    static let reviewFindings = "1. App/RankingView.swift:12\nnil のときに落ちる"
    static let ciFindings = "チェック: build / build（failure）\nerror: cannot find 'Ranking' in scope"

    /// 実装の試行と、子 PR のレビューの試行（同じ PR と head を見た直す判定）を置き、子 PR を開いておく
    func fixture(remoteHead: String = Self.head) async throws -> Fixture {
        let fixture = Fixture()
        try await fixture.prepare()
        let claude = AttemptFile.Claude(model: "claude-opus-5-5", session: "s-impl", estimatedCostUsd: 0.4)
        try await fixture.record(fixture.job(.implementTask, "01"), outputs: .init(pullRequest: 41, commit: Self.head), claude: claude)
        let reviewed = PullRequestInput(pullRequest: 41, head: Self.head)
        let review = AttemptFile.Outputs(pullRequest: 41, commit: Self.head, verdict: .fixReview, findings: Self.reviewFindings)
        try await fixture.record(fixture.job(.reviewTask, "02", input: reviewed.jobInput), outputs: review, endedAt: 60)
        // 別の head を見たレビューの CI の失敗（使わない）
        let older = PullRequestInput(pullRequest: 41, head: sha("0"))
        let ci = AttemptFile.Outputs(pullRequest: 41, commit: sha("0"), verdict: .fixCI, findings: "古い head の失敗")
        try await fixture.record(fixture.job(.reviewTask, "03", input: older.jobInput), outputs: ci, endedAt: 30)
        fixture.git.update { $0.remote[Fixture.branches.task] = remoteHead }
        fixture.pulls.update { state in
            state.pulls[41] = Fixture.openPull(head: remoteHead)
        }
        return fixture
    }

    func fix(_ fixture: Fixture, _ runner: FakeTaskRunner, reason: FixTaskInput.Reason = .review) async throws -> JobResult {
        let input = FixTaskInput(pullRequest: 41, head: Self.head, reason: reason)
        let job = fixture.job(.fixTask, "05", input: input.jobInput)
        return try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)
    }

    @Test func resumesImplementationConversationWithRecordedFindings() async throws {
        let fixture = try await fixture()
        let runner = FakeTaskRunner([FakeTaskRunner.done("nil のときに空の一覧を出すようにした。")]) { fixture.git.update { $0.dirty = true } }
        let result = try await fix(fixture, runner)
        #expect(result.failure == nil)
        #expect(result.outputs?.commit == sha("1"))
        #expect(fixture.git.current.remote[Fixture.branches.task] == sha("1"))
        #expect(result.outputs?.pullRequest == 41)
        #expect(result.outputs?.branch == Fixture.branches.task)
        #expect(result.outputs?.report?.summary == "nil のときに空の一覧を出すようにした。")
        #expect(result.claude?.session == "s-impl")

        // 実装の会話を、レビューの試行に書かれた直すことを付けて再開する
        let call = try #require(runner.calls.first)
        #expect(call.kind == .fixTask)
        #expect(call.resume == "s-impl")
        #expect(call.prompt.contains("子 PR #41 のレビューで"))
        #expect(call.prompt.contains(Self.reviewFindings))
        #expect(fixture.git.current.commits.first?.hasPrefix("ランキングの画面を作る（レビューの指摘を直す）") == true)
    }

    @Test func picksFindingsForReasonAndLatestConversation() async throws {
        let fixture = try await fixture()
        // 同じ head の CI の失敗と、前の直しの会話（後に終わったもの）
        let reviewed = PullRequestInput(pullRequest: 41, head: Self.head)
        let ci = AttemptFile.Outputs(pullRequest: 41, commit: Self.head, verdict: .fixCI, findings: Self.ciFindings)
        try await fixture.record(fixture.job(.reviewTask, "04", input: reviewed.jobInput), outputs: ci, endedAt: 90)
        let claude = AttemptFile.Claude(model: "claude-opus-5-5", session: "s-fix1", estimatedCostUsd: 0.6)
        try await fixture.record(fixture.job(.fixTask, "06"), outputs: .init(commit: Self.head), claude: claude, endedAt: 120)

        let runner = FakeTaskRunner([FakeTaskRunner.done(session: "s-fix1")]) { fixture.git.update { $0.dirty = true } }
        let result = try await fix(fixture, runner, reason: .ci)
        #expect(result.failure == nil)
        let call = try #require(runner.calls.first)
        #expect(call.resume == "s-fix1")
        #expect(call.prompt.contains("CI が落ちました"))
        #expect(call.prompt.contains("error: cannot find 'Ranking' in scope"))
        #expect(!call.prompt.contains("古い head の失敗"))
    }

    @Test func returnsFixAlreadyPushedWithoutAskingClaudeAgain() async throws {
        // 前の試行が直して push した後、記録する前に落ちた
        let fixture = try await fixture(remoteHead: sha("9"))
        fixture.git.update { $0.ancestors = ["\(Self.head)..\(sha("9"))"] }
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let result = try await fix(fixture, runner)
        #expect(result.failure == nil)
        #expect(result.outputs?.commit == sha("9"))
        #expect(runner.calls.isEmpty)
        #expect(fixture.git.current.commits.isEmpty)
    }

    @Test func refusesBranchThatDivergedFromHead() async throws {
        let fixture = try await fixture(remoteHead: sha("8"))
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let result = try await fix(fixture, runner)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(runner.calls.isEmpty)
    }

    @Test func keepsHeadWhenClaudeChangedNothing() async throws {
        // 指摘が誤っていると判断して、何も変えなかった。同じ head で、もう一度レビューを受ける
        let fixture = try await fixture()
        let result = try await fix(fixture, FakeTaskRunner([FakeTaskRunner.done("指摘は誤り。nil にはならない。")]))
        #expect(result.failure == nil)
        #expect(result.outputs?.commit == Self.head)
        #expect(result.outputs?.report?.summary == "指摘は誤り。nil にはならない。")
    }

    @Test func failsWithoutFindingsConversationOrOpenPullRequest() async throws {
        let empty = Fixture()
        try await empty.prepare()
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let missing = try await fix(empty, runner)
        #expect(missing.failure?.message.contains("直すこと") == true)

        // 直すことはあるが、実装の会話が無い
        let noSession = Fixture()
        try await noSession.prepare()
        let reviewed = PullRequestInput(pullRequest: 41, head: Self.head)
        let review = AttemptFile.Outputs(pullRequest: 41, commit: Self.head, verdict: .fixReview, findings: Self.reviewFindings)
        try await noSession.record(noSession.job(.reviewTask, "02", input: reviewed.jobInput), outputs: review)
        let missingSession = try await fix(noSession, runner)
        #expect(missingSession.failure?.message.contains("実装の会話") == true)

        let closed = try await fixture()
        closed.pulls.update { $0.pulls[41]?.state = .closed }
        let notOpen = try await fix(closed, runner)
        #expect(notOpen.failure?.message.contains("開いていない") == true)

        // 子 PR の向き先が作業ブランチでない
        let moved = try await fixture()
        moved.pulls.update { $0.pulls[41]?.baseRef = "develop" }
        let wrongBase = try await fix(moved, runner)
        #expect(wrongBase.failure?.message.contains("向き") == true)
        #expect(runner.calls.isEmpty)
    }

    @Test func refusesConversationLeftOnAnotherMac() async throws {
        // 実装の会話は、それを動かした Mac の Claude の設定フォルダにだけ残る
        let fixture = try await fixture()
        let claude = AttemptFile.Claude(model: "claude-opus-5-5", session: "s-other", estimatedCostUsd: 0.4)
        let job = fixture.job(.fixTask, "07")
        try await fixture.files.create(job, at: StatePath.job(Fixture.repo, epic: Fixture.epic, job: job.id), message: "job")
        let time = Timestamp(Fixture.start.addingTimeInterval(200))
        let attempt = AttemptFile(
            job: job.id,
            number: 1,
            mac: MacName(rawValue: "mac-mini")!,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            claude: claude
        )
        let path = StatePath.attempt(Fixture.repo, epic: Fixture.epic, job: job.id, number: 1)
        try await fixture.files.create(attempt, at: path, message: "attempt")
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let result = try await fix(fixture, runner)
        #expect(result.failure?.message.contains("mac-mini") == true)
        #expect(runner.calls.isEmpty)
    }
}
