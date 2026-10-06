import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct LoopStatusSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let running = LoopStatus(stateFileExists: true, processAlive: true)
    private static let stalled = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)

    private static let goal = """
        # ゴール

        ## タスク
        - [x] 【FEAT】A | label: enhancement
        - [x] 【FEAT】B | label: enhancement  ※保留（2026-10-06）: 理由
        - [ ] 【FEAT】C | label: enhancement  ※回答待ち（PR #3 / ask id 4）
        - [ ] 【FEAT】D | label: enhancement

        ## 注意点
        - チェックボックスでない行は数えない
        """

    private static func epic(goal: String = Self.goal, discussion: Int? = 197, prepared: Bool = true) -> EpicSnapshot {
        EpicSnapshot(branch: "epic/loop-status", goal: goal, state: "## メモ\n", discussion: discussion, loopPrepared: prepared)
    }

    private func report(_ facts: LoopStatusFacts) -> LoopStatusReport {
        LoopStatusSummary.report(for: facts, now: now)
    }

    @Test func reportsRunningLoopWithEpicProgressAndLastActivity() {
        let activity = now.addingTimeInterval(-180)
        let report = report(.init(status: Self.running, snapshot: Self.epic(), lastActivityAt: activity))
        #expect(report == LoopStatusReport(
            state: .running,
            epic: "epic/loop-status",
            discussion: 197,
            progress: .init(completed: 2, total: 4),
            lastActivityAt: activity,
            checkedAt: now
        ))
        // state ファイルだけがある（オーケストレーターの再起動の前に起動した）ループも実行中
        let adopted = LoopStatus(stateFileExists: true, processAlive: false)
        #expect(self.report(.init(status: adopted, snapshot: Self.epic())).state == .running)
    }

    @Test func prefersUsageLimitOverRunningAndGaveUp() {
        let until = now.addingTimeInterval(3600)
        let limited = report(.init(status: Self.stalled, snapshot: Self.epic(), usageLimitedUntil: until, gaveUp: true))
        #expect(limited.state == .usageLimited)
        #expect(limited.usageLimitedUntil == until)
        #expect(limited.epic == "epic/loop-status")
        #expect(report(.init(status: Self.running, snapshot: Self.epic(), usageLimitedUntil: until)).state == .usageLimited)

        // 解除の時刻を過ぎていれば上限では待っていない
        let expired = report(.init(status: Self.running, snapshot: Self.epic(), usageLimitedUntil: now))
        #expect(expired.state == .running)
        #expect(expired.usageLimitedUntil == nil)
    }

    @Test func reportsGaveUpUnlessRunning() {
        #expect(report(.init(status: Self.stalled, snapshot: Self.epic(), gaveUp: true)).state == .gaveUp)
        #expect(report(.init(status: Self.running, snapshot: Self.epic(), gaveUp: true)).state == .running)
        // epic が無くても（起動を諦めた）異常終了
        #expect(report(.init(status: .idle, snapshot: nil, gaveUp: true, readyDiscussion: 5)).state == .gaveUp)
    }

    @Test func doesNotReportFailedResumeAsRunning() {
        // 再開に失敗した（Orchestrator+LoopResume）ループは、state ファイルが残ったまま `stalled` になる
        let failedResume = LoopStatus(stateFileExists: true, processAlive: false, stalled: true)
        #expect(report(.init(status: failedResume, snapshot: Self.epic())).state == .waitingToStart)
        #expect(report(.init(status: failedResume, snapshot: Self.epic(), gaveUp: true)).state == .gaveUp)
    }

    @Test func classifiesStoppedEpicByRemainingTasks() {
        // 回答待ちでない未完了のタスクが残っている（再開を待っている・手で止めた）
        #expect(report(.init(status: Self.stalled, snapshot: Self.epic())).state == .waitingToStart)
        #expect(report(.init(status: .idle, snapshot: Self.epic())).state == .waitingToStart)

        // 回答待ちのタスクだけが残っている
        let waiting = Self.goal.replacingOccurrences(of: "- [ ] 【FEAT】D", with: "- [x] 【FEAT】D")
        let answer = report(.init(status: .idle, snapshot: Self.epic(goal: waiting)))
        #expect(answer.state == .waitingForAnswer)
        #expect(answer.progress == .init(completed: 3, total: 4))
        // 回答が付いて再開を待っている（再開に失敗した）なら、人を待っていない
        let answered = report(.init(status: .idle, snapshot: Self.epic(goal: waiting), hasAnsweredQuestions: true))
        #expect(answered.state == .waitingToStart)

        // すべて終わった（最終 PR のマージ待ち）。次の Discussion が待っていても完了を出す
        let done = waiting.replacingOccurrences(of: "- [ ] 【FEAT】C", with: "- [x] 【FEAT】C")
        let completed = report(.init(status: .idle, snapshot: Self.epic(goal: done), readyDiscussion: 300))
        #expect(completed.state == .completed)
        #expect(completed.discussion == 197)
        #expect(completed.progress == .init(completed: 4, total: 4))
    }

    @Test func treatsMergedEpicAsNoLoop() {
        let done = "- [x] 【FEAT】A\n"
        let merged = report(.init(status: .idle, snapshot: Self.epic(goal: done), epicMerged: true, lastActivityAt: now))
        #expect(merged == LoopStatusReport(state: .noLoop, checkedAt: now))

        let next = report(.init(status: .idle, snapshot: Self.epic(goal: done), readyDiscussion: 300, epicMerged: true))
        #expect(next == LoopStatusReport(state: .waitingToStart, discussion: 300, checkedAt: now))
    }

    @Test func reportsReadyDiscussionOrNoLoopWithoutPreparedEpic() {
        let ready = report(.init(status: .idle, snapshot: nil, readyDiscussion: 300))
        #expect(ready == LoopStatusReport(state: .waitingToStart, discussion: 300, checkedAt: now))
        #expect(report(.init(status: .idle, snapshot: nil, lastActivityAt: now)) == LoopStatusReport(state: .noLoop, checkedAt: now))

        // 準備を終えていない・epic でないブランチ・goal が無い制御用 worktree は epic として扱わない
        for snapshot in [
            Self.epic(prepared: false),
            EpicSnapshot(branch: "develop", goal: Self.goal, state: nil, loopPrepared: true),
            EpicSnapshot(branch: "epic/x", goal: nil, state: nil, loopPrepared: true),
            EpicSnapshot(branch: nil, goal: Self.goal, state: nil, loopPrepared: true)
        ] {
            #expect(report(.init(status: .idle, snapshot: snapshot)) == LoopStatusReport(state: .noLoop, checkedAt: now))
        }
        // state ファイルを確かめられない（`nil`）だけでは実行中とみなさない
        let unknown = LoopStatus(stateFileExists: nil, processAlive: false)
        #expect(report(.init(status: unknown, snapshot: nil)).state == .noLoop)
    }

    @Test func keepsDiscussionUnsetForManuallyStartedEpic() {
        let manual = report(.init(status: Self.running, snapshot: Self.epic(discussion: nil)))
        #expect(manual.epic == "epic/loop-status")
        #expect(manual.discussion == nil)
    }

    @Test func countsOnlyChecklistLines() {
        #expect(LoopStatusSummary.progress(in: Self.goal) == .init(completed: 2, total: 4))
        #expect(LoopStatusSummary.progress(in: "  - [X] 大文字\n- [ ] 未完了\n- 普通の箇条書き\n") == .init(completed: 1, total: 2))
        #expect(LoopStatusSummary.progress(in: "# タスクなし\n") == nil)
        let report = report(.init(status: Self.running, snapshot: Self.epic(goal: "# タスクなし\n")))
        #expect(report.progress == nil)
    }

    @Test func picksLatestActivity() {
        let older = now.addingTimeInterval(-600)
        #expect(LoopStatusSummary.lastActivity(older, now, nil) == now)
        #expect(LoopStatusSummary.lastActivity(nil, nil) == nil)
    }

    @Test func reportHoldsNoLocalPaths() {
        let report = report(.init(status: Self.running, snapshot: Self.epic(), lastActivityAt: now))
        #expect(!report.issueBody.contains("/Users/"))
        #expect(!report.issueBody.contains(".claude/"))
        #expect(!report.issueBody.contains("## メモ"))
    }
}

struct LoopGiveUpTests {
    private static let stalled = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)
    private static let epic = EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: "## メモ\n")

    @Test func stallWatcherHasGivenUpOnlyForSameEpic() {
        var watcher = StallWatcher()
        for _ in 0...StallWatcher.maxAttempts {
            _ = watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: Self.epic)
        }
        #expect(watcher.hasGivenUp(repositoryKey: "r", snapshot: Self.epic))
        #expect(!watcher.hasGivenUp(repositoryKey: "other", snapshot: Self.epic))
        // epic が進んだら数え直す
        let progressed = EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: "## メモ\n")
        #expect(!watcher.hasGivenUp(repositoryKey: "r", snapshot: progressed))
    }

    @Test func launchTrackerHasGivenUpPerRepository() {
        var tracker = LaunchTracker()
        let discussion = ReadyDiscussion.fixture(number: 12)
        tracker.recordLaunchFailure(of: discussion, repositoryKey: "r")
        #expect(!tracker.hasGivenUp(repositoryKey: "r"))
        for _ in 1..<LaunchTracker.maxAttempts {
            tracker.recordLaunchFailure(of: discussion, repositoryKey: "r")
        }
        #expect(tracker.hasGivenUp(repositoryKey: "r"))
        #expect(!tracker.hasGivenUp(repositoryKey: "other"))
        tracker.forgiveFailures(repositoryKey: "r")
        #expect(!tracker.hasGivenUp(repositoryKey: "r"))
    }
}
