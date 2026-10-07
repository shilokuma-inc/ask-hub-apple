import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct LoopStatusPublisherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])
    private let key = "o/r"

    private func report(_ state: LoopStatusReport.State, at date: Date) -> LoopStatusReport {
        LoopStatusReport(state: state, epic: "epic/x", checkedAt: date)
    }

    private func record(
        _ number: Int, author: String? = "mrs1669", isOpen: Bool = true, minutesAgo: Double = 0, body: String
    ) -> LoopStatusIssueRecord {
        let updatedAt = now.addingTimeInterval(-minutesAgo * 60)
        return LoopStatusIssueRecord(number: number, author: author, isOpen: isOpen, updatedAt: updatedAt, body: body)
    }

    @Test func looksUpFirstAndCreatesWhenNoTrustedIssueExists() {
        var publisher = LoopStatusPublisher()
        let running = report(.running, at: now)
        #expect(publisher.action(repositoryKey: key, report: running, now: now) == .lookUp)

        // 信用しない author の Issue は使わない
        publisher.adopt([record(5, author: "someone", body: running.issueBody)], repositoryKey: key, trustedAuthors: trusted)
        #expect(publisher.action(repositoryKey: key, report: running, now: now) == .create(body: running.issueBody))
    }

    @Test func writesOnlyWhenStatusChangesOrIntervalPasses() {
        var publisher = LoopStatusPublisher()
        let running = report(.running, at: now)
        publisher.recordWritten(running, number: 7, repositoryKey: key)

        // 状態が同じで間隔より前なら書かない
        let later = now.addingTimeInterval(LoopStatusReport.updateInterval - 1)
        #expect(publisher.action(repositoryKey: key, report: report(.running, at: later), now: later) == .none)

        // 状態が変われば、間隔より前でも書く
        let changed = report(.waitingForAnswer, at: later)
        #expect(publisher.action(repositoryKey: key, report: changed, now: later) == .update(number: 7, body: changed.issueBody))

        // 間隔を過ぎたら、確認時刻を書き直す
        let interval = now.addingTimeInterval(LoopStatusReport.updateInterval)
        let refreshed = report(.running, at: interval)
        #expect(publisher.action(repositoryKey: key, report: refreshed, now: interval) == .update(number: 7, body: refreshed.issueBody))
    }

    @Test func adoptsNewestOpenTrustedIssueAndReadsItsStatus() {
        var publisher = LoopStatusPublisher()
        let written = report(.running, at: now.addingTimeInterval(-60))
        let issues = [
            record(1, minutesAgo: 30, body: report(.completed, at: now).issueBody),
            record(2, minutesAgo: 1, body: written.issueBody),
            record(3, isOpen: false, minutesAgo: 0, body: written.issueBody),
            record(4, author: "someone", minutesAgo: 0, body: written.issueBody)
        ]
        publisher.adopt(issues, repositoryKey: key, trustedAuthors: trusted)

        // 前回のオーケストレーターが書いた状態と同じなら、書き直さない
        #expect(publisher.action(repositoryKey: key, report: report(.running, at: now), now: now) == .none)
        let changed = report(.gaveUp, at: now)
        #expect(publisher.action(repositoryKey: key, report: changed, now: now) == .update(number: 2, body: changed.issueBody))
    }

    @Test func reopensClosedIssueAndRewritesUnreadableBody() {
        var closed = LoopStatusPublisher()
        let running = report(.running, at: now)
        closed.adopt([record(3, isOpen: false, body: running.issueBody)], repositoryKey: key, trustedAuthors: trusted)
        // 閉じられていれば、同じ状態でも書き直して開き直す
        #expect(closed.action(repositoryKey: key, report: running, now: now) == .update(number: 3, body: running.issueBody))

        var edited = LoopStatusPublisher()
        edited.adopt([record(4, body: "人が書き換えた本文")], repositoryKey: key, trustedAuthors: trusted)
        #expect(edited.action(repositoryKey: key, report: running, now: now) == .update(number: 4, body: running.issueBody))
    }

    @Test func looksUpAgainAfterForgetting() {
        var publisher = LoopStatusPublisher()
        publisher.recordWritten(report(.running, at: now), number: 7, repositoryKey: key)
        publisher.forget(repositoryKey: key)
        #expect(publisher.action(repositoryKey: key, report: report(.running, at: now), now: now) == .lookUp)
    }
}

// MARK: - 状態用の Issue の書き出し

extension OrchestratorTests {
    private static let doneGoal = "- [x] 【FEAT】A\n- [x] 【FEAT】B\n"

    @Test func createsStatusIssueOnceAndRewritesOnlyOnChangeOrInterval() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] A\n- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        let activity = Date(timeIntervalSince1970: 1_800_000_000 - 120)
        runtime.setLastActivity(activity)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime) { clock.withLock { $0 } }

        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
        let report = try #require(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) })
        #expect(report == LoopStatusReport(
            state: .running,
            epic: "epic/mvp",
            discussion: 12,
            progress: .init(completed: 1, total: 2, deferred: 0),
            lastActivityAt: activity,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        // 本文にローカルパスを書かない
        #expect(github.loopStatusIssuesByNumber[101]?.body.contains("/src/ask-hub-apple") == false)

        // 変わらなければ、間隔より前は書かず、一覧も取り直さない
        clock.withLock { $0 = $0.addingTimeInterval(60) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(github.loopStatusIssueListings == 1)

        // 状態が変われば書き換える
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
        #expect(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) }?.state == .waitingToStart)

        // 間隔を過ぎたら確認時刻だけ書き直す
        clock.withLock { $0 = $0.addingTimeInterval(LoopStatusReport.updateInterval) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.count == 2)
        #expect(github.createdLoopStatusIssues.count == 1)
    }

    @Test func reusesExistingTrustedIssueAndRetriesAfterFailure() async throws {
        let github = FakeGitHub([.success([])])
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 5, author: "someone", isOpen: true, updatedAt: .distantFuture, body: "spam"),
            LoopStatusIssueRecord(number: 9, author: "mrs1669", isOpen: false, updatedAt: .distantPast, body: "")
        ])
        github.setLoopStatusFails(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())

        // 書けなくてもほかの判定は続け、次のポーリングで書き直す
        try await orchestrator.pollOnce()
        #expect(logs.recorded.contains { $0.hasPrefix("shilokuma-inc/ask-hub-apple にループの状態を書けませんでした") })

        github.setLoopStatusFails(false)
        try await orchestrator.pollOnce()
        // 信用する author の閉じた Issue を開き直して使う
        #expect(github.createdLoopStatusIssues.isEmpty)
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#9"])
        #expect(github.loopStatusIssuesByNumber[9]?.isOpen == true)
        #expect(github.loopStatusIssuesByNumber[9].flatMap { LoopStatusReport.parse($0.body) }?.state == .noLoop)
    }

    @Test func reportsReadyDiscussionAndMergedEpic() async throws {
        let github = FakeGitHub([.success([.fixture(number: 30), .fixture(number: 20), .fixture(repository: "other/repo", number: 5)])])
        let runtime = FakeRuntime()
        // 前の epic は完了し、最終 PR がマージ済み。次の Discussion は起動を待っている
        runtime.set(LoopStatus(stateFileExists: false, processAlive: true))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: Self.doneGoal, state: nil, discussion: 12, loopPrepared: true))
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 40, isOpen: false, isMerged: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        let report = try #require(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) })
        // プロセスが生きている（新しい Discussion のループを起動した）ので実行中。マージ済みの epic は載せない
        #expect(report.state == .running)
        #expect(report.epic == nil)

        // state ファイルを確かめられない間は起動しない（LaunchPlanner）。マージ済みの epic は無視して、次の Discussion を待っていると出す
        runtime.set(LoopStatus(stateFileExists: nil, processAlive: false))
        try await orchestrator.pollOnce()
        #expect(runtime.launched.isEmpty)
        let waiting = try #require(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) })
        #expect(waiting.state == .waitingToStart)
        #expect(waiting.discussion == 20)
    }

    @Test func reportsWaitingForAnswerWhileOnlyAskedTasksRemain() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(
            branch: "epic/mvp", goal: "- [x] A\n- [ ] B ※回答待ち（PR #3 / ask id 4）\n", state: nil, loopPrepared: true
        ))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) }?.state == .waitingForAnswer)
    }
}
