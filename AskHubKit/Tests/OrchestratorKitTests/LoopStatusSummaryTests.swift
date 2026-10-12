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

    private func loops(_ facts: LoopStatusFacts) -> AutomaticLoops {
        LoopStatusSummary.loops(for: facts, now: now)
    }

    /// ループが 1 つだけのときの、その状態（0 個・2 個以上なら `nil`）
    private func onlyReport(_ facts: LoopStatusFacts) -> LoopStatusReport? {
        let reports = loops(facts).reports
        return reports.count == 1 ? reports.first : nil
    }

    /// Discussion の番号と状態の組
    private func states(_ facts: LoopStatusFacts) -> [String] {
        loops(facts).reports.map { "#\($0.discussion ?? 0) \($0.state.rawValue)" }
    }

    @Test func reportsRunningLoopWithEpicProgressAndLastActivity() {
        let activity = now.addingTimeInterval(-180)
        let builds = LoopStatusBuilds(running: [], latest: [], moved: [])
        let report = onlyReport(.init(status: Self.running, snapshot: Self.epic(), lastActivityAt: activity, builds: builds))
        #expect(report == LoopStatusReport(
            state: .running,
            epic: "epic/loop-status",
            discussion: 197,
            progress: .init(completed: 2, total: 4, deferred: 1),
            lastActivityAt: activity,
            checkedAt: now,
            builds: builds
        ))
        // state ファイルだけがある（オーケストレーターの再起動の前に起動した）ループも実行中
        let adopted = LoopStatus(stateFileExists: true, processAlive: false)
        #expect(onlyReport(.init(status: adopted, snapshot: Self.epic()))?.state == .running)
        #expect(!loops(.init(status: adopted, snapshot: Self.epic())).includesUnknownLoop)
    }

    @Test func prefersUsageLimitOverRunningAndGaveUp() throws {
        let until = now.addingTimeInterval(3600)
        let limited = try #require(onlyReport(.init(status: Self.stalled, snapshot: Self.epic(), usageLimitedUntil: until, gaveUp: true)))
        #expect(limited.state == .usageLimited)
        #expect(limited.usageLimitedUntil == until)
        #expect(limited.epic == "epic/loop-status")
        #expect(onlyReport(.init(status: Self.running, snapshot: Self.epic(), usageLimitedUntil: until))?.state == .usageLimited)

        // 上限はこの Mac のすべての自動ループが待つ（epic・起動した Discussion・待っている Discussion）
        let all = loops(.init(
            status: Self.running, snapshot: Self.epic(), usageLimitedUntil: until,
            readyDiscussions: [300], launchedDiscussions: [250], givenUpDiscussions: [240]
        ))
        #expect(all.reports.map(\.discussion) == [197, 240, 250, 300])
        #expect(all.reports.allSatisfy { $0.state == .usageLimited && $0.usageLimitedUntil == until })

        // 解除の時刻を過ぎていれば上限では待っていない
        let expired = try #require(onlyReport(.init(status: Self.running, snapshot: Self.epic(), usageLimitedUntil: now)))
        #expect(expired.state == .running)
        #expect(expired.usageLimitedUntil == nil)
    }

    @Test func reportsGaveUpUnlessRunning() {
        #expect(onlyReport(.init(status: Self.stalled, snapshot: Self.epic(), gaveUp: true))?.state == .gaveUp)
        #expect(onlyReport(.init(status: Self.running, snapshot: Self.epic(), gaveUp: true))?.state == .running)
        // epic の Discussion の起動を諦めた（準備は終えたが、ループを始められなかった）
        #expect(onlyReport(.init(status: .idle, snapshot: Self.epic(), givenUpDiscussions: [197]))?.state == .gaveUp)
        // epic が無くても、起動を諦めた Discussion は異常終了
        #expect(states(.init(status: .idle, snapshot: nil, gaveUp: true, readyDiscussions: [5], givenUpDiscussions: [5])) == ["#5 gave-up"])
        // epic の再開を諦めた（`gaveUp`）だけで epic が無ければ、ほかの Discussion の状態にしない
        #expect(states(.init(status: .idle, snapshot: nil, gaveUp: true, readyDiscussions: [5])) == ["#5 waiting-to-start"])
    }

    @Test func doesNotReportFailedResumeAsRunning() {
        // 再開に失敗した（Orchestrator+LoopResume）ループは、state ファイルが残ったまま `stalled` になる
        let failedResume = LoopStatus(stateFileExists: true, processAlive: false, stalled: true)
        #expect(onlyReport(.init(status: failedResume, snapshot: Self.epic()))?.state == .waitingToStart)
        #expect(onlyReport(.init(status: failedResume, snapshot: Self.epic(), gaveUp: true))?.state == .gaveUp)
    }

    @Test func classifiesStoppedEpicByRemainingTasks() throws {
        // 回答待ちでない未完了のタスクが残っている（再開を待っている・手で止めた）
        #expect(onlyReport(.init(status: Self.stalled, snapshot: Self.epic()))?.state == .waitingToStart)
        #expect(onlyReport(.init(status: .idle, snapshot: Self.epic()))?.state == .waitingToStart)

        // 回答待ちのタスクだけが残っている
        let waiting = Self.goal.replacingOccurrences(of: "- [ ] 【FEAT】D", with: "- [x] 【FEAT】D")
        let answer = try #require(onlyReport(.init(status: .idle, snapshot: Self.epic(goal: waiting))))
        #expect(answer.state == .waitingForAnswer)
        #expect(answer.progress == .init(completed: 3, total: 4, deferred: 1))
        // 回答が付いて再開を待っている（再開に失敗した）なら、人を待っていない
        let answered = onlyReport(.init(status: .idle, snapshot: Self.epic(goal: waiting), hasAnsweredQuestions: true))
        #expect(answered?.state == .waitingToStart)

        // すべて終わった（最終 PR のマージ待ち）。次の Discussion が待っていれば、そちらは別のループとして開始待ちにする
        let done = waiting.replacingOccurrences(of: "- [ ] 【FEAT】C", with: "- [x] 【FEAT】C")
        let next = loops(.init(status: .idle, snapshot: Self.epic(goal: done), readyDiscussions: [300])).reports
        #expect(next.map(\.state) == [.completed, .waitingToStart])
        #expect(next.first?.discussion == 197)
        #expect(next.first?.progress == .init(completed: 4, total: 4, deferred: 1))
        #expect(next.last == LoopStatusReport(state: .waitingToStart, discussion: 300, checkedAt: now))
    }

    @Test func treatsMergedEpicAsFinishedLoop() {
        let done = "- [x] 【FEAT】A\n"
        let merged = loops(.init(status: .idle, snapshot: Self.epic(goal: done), epicMerged: true, lastActivityAt: now))
        #expect(merged == AutomaticLoops(reports: []))

        let next = loops(.init(status: .idle, snapshot: Self.epic(goal: done), readyDiscussions: [300], epicMerged: true))
        #expect(next == AutomaticLoops(reports: [LoopStatusReport(state: .waitingToStart, discussion: 300, checkedAt: now)]))
    }

    @Test func reportsPreparedEpicAndLaunchedDiscussionSeparately() {
        let done = "- [x] 【FEAT】A\n"
        // 完了した #197 の最終 PR のマージ待ちの間に #30 を起動した。動いているプロセスは #30 のもので、#197 は完了のまま
        let facts = LoopStatusFacts(
            status: Self.running, snapshot: Self.epic(goal: done), readyDiscussions: [30, 40], launchedDiscussions: [30]
        )
        #expect(states(facts) == ["#30 running", "#40 waiting-to-start", "#197 completed"])
        #expect(loops(facts).reports.first == LoopStatusReport(state: .running, discussion: 30, checkedAt: now))
        #expect(!loops(facts).includesUnknownLoop)

        // #10 の起動を諦めた後に #20 を準備して、回答を待っている。#10 は異常終了、#20 は epic の状態
        let waiting = Self.goal.replacingOccurrences(of: "- [ ] 【FEAT】D", with: "- [x] 【FEAT】D")
        let epic = Self.epic(goal: waiting, discussion: 20)
        let givenUp = LoopStatusFacts(status: .idle, snapshot: epic, readyDiscussions: [10], givenUpDiscussions: [10])
        #expect(states(givenUp) == ["#10 gave-up", "#20 waiting-for-answer"])

        // ループの開始を確かめた・ラベルを外した Discussion が準備を終えた epic のものなら、epic のループとして実行中にする
        let started = onlyReport(.init(status: Self.running, snapshot: Self.epic(), launchedDiscussions: [197]))
        #expect(started?.state == .running)
        #expect(started?.progress == .init(completed: 2, total: 4, deferred: 1))
    }

    @Test func writesLaunchedDiscussionsWithoutPreparedEpic() {
        // 起動したが準備が終わっていない間は、起動した Discussion のループとして実行中（待っている ready の Discussion は開始待ち）
        let preparing = Self.epic(prepared: false)
        let started = loops(.init(status: Self.running, snapshot: preparing, readyDiscussions: [20, 30], launchedDiscussions: [30]))
        #expect(started.reports == [
            LoopStatusReport(state: .waitingToStart, discussion: 20, checkedAt: now),
            LoopStatusReport(state: .running, discussion: 30, checkedAt: now)
        ])
        #expect(!started.includesUnknownLoop)
        // 起動の記録が無いのに動いている（手で始めたループなど）なら、どの Discussion のループか分からない
        let manual = loops(.init(status: Self.running, snapshot: preparing, readyDiscussions: [20], givenUpDiscussions: [10]))
        #expect(manual.reports.map(\.state) == [.gaveUp, .waitingToStart])
        #expect(manual.includesUnknownLoop)
    }

    @Test func reportsReadyDiscussionsOrNoLoopWithoutPreparedEpic() {
        let ready = loops(.init(status: .idle, snapshot: nil, readyDiscussions: [300, 301]))
        #expect(ready.reports.map(\.discussion) == [300, 301])
        #expect(ready.reports.allSatisfy { $0.state == .waitingToStart })
        #expect(loops(.init(status: .idle, snapshot: nil, lastActivityAt: now)) == AutomaticLoops(reports: []))

        // 準備を終えていない・epic でないブランチ・goal が無い制御用 worktree は epic として扱わない
        for snapshot in [
            Self.epic(prepared: false),
            EpicSnapshot(branch: "develop", goal: Self.goal, state: nil, loopPrepared: true),
            EpicSnapshot(branch: "epic/x", goal: nil, state: nil, loopPrepared: true),
            EpicSnapshot(branch: nil, goal: Self.goal, state: nil, loopPrepared: true)
        ] {
            #expect(loops(.init(status: .idle, snapshot: snapshot)) == AutomaticLoops(reports: []))
        }
        // state ファイルを確かめられない（`nil`）だけでは実行中とみなさない
        let unknown = LoopStatus(stateFileExists: nil, processAlive: false)
        #expect(loops(.init(status: unknown, snapshot: nil)) == AutomaticLoops(reports: []))
    }

    @Test func marksUnknownLoopWhileDiscussionCannotBeTold() {
        // 手で始めた epic（ゴール元の記録が無い）は書かない
        let manual = loops(.init(status: Self.running, snapshot: Self.epic(discussion: nil), readyDiscussions: [20]))
        #expect(manual.reports.map(\.discussion) == [20])
        #expect(manual.includesUnknownLoop)
        // オーケストレーターを起動してから ready の一覧をまだ取得していない（上限で待機中に再起動した）
        let restarted = loops(.init(status: .idle, snapshot: Self.epic(), readyDiscussions: nil))
        #expect(restarted.reports.map(\.discussion) == [197])
        #expect(restarted.includesUnknownLoop)
    }

    @Test func countsOnlyChecklistLines() {
        #expect(LoopStatusSummary.progress(in: Self.goal) == .init(completed: 2, total: 4, deferred: 1))
        #expect(LoopStatusSummary.progress(in: "  - [X] 大文字\n- [ ] 未完了\n- 普通の箇条書き\n") == .init(completed: 1, total: 2, deferred: 0))
        #expect(LoopStatusSummary.progress(in: "# タスクなし\n") == nil)
        let report = onlyReport(.init(status: Self.running, snapshot: Self.epic(goal: "# タスクなし\n")))
        #expect(report?.epic == "epic/loop-status")
        #expect(report?.progress == nil)
    }

    @Test func countsDeferredTasksClosedWithMark() {
        let goal = """
            - [x] 【FEAT】A | label: enhancement  ※保留（2026-10-06）: 人の判断待ち
            - [X] 【FEAT】B | label: enhancement  ※保留（2026-10-07）: 前提が違った
            - [x] 【FEAT】C | label: enhancement
            - [ ] 【FEAT】D | label: enhancement  ※保留にするか迷う（未完了なので数えない）
            - [ ] 【FEAT】E | label: enhancement  ※回答待ち（PR #3 / ask id 4）
            """
        #expect(LoopStatusSummary.progress(in: goal) == .init(completed: 3, total: 5, deferred: 2))
    }

    @Test func picksLatestActivity() {
        let older = now.addingTimeInterval(-600)
        #expect(LoopStatusSummary.lastActivity(older, now, nil) == now)
        #expect(LoopStatusSummary.lastActivity(nil, nil) == nil)
    }

    @Test func reportHoldsNoLocalPaths() throws {
        let report = try #require(onlyReport(.init(status: Self.running, snapshot: Self.epic(), lastActivityAt: now)))
        #expect(!report.commentBody.contains("/Users/"))
        #expect(!report.commentBody.contains(".claude/"))
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
        #expect(tracker.givenUpDiscussions(repositoryKey: "r").isEmpty)
        for _ in 1..<LaunchTracker.maxAttempts {
            tracker.recordLaunchFailure(of: discussion, repositoryKey: "r")
        }
        #expect(tracker.givenUpDiscussions(repositoryKey: "r") == [12])
        #expect(tracker.givenUpDiscussions(repositoryKey: "other").isEmpty)
        tracker.forgiveFailures(repositoryKey: "r")
        #expect(tracker.givenUpDiscussions(repositoryKey: "r").isEmpty)
    }
}
