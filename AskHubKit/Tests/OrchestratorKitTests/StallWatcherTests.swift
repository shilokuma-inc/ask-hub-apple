@testable import OrchestratorKit
import Testing

struct StallWatcherTests {
    private static let stalled = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)
    private static let epic = EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: "## メモ\n")

    @Test func resumesOnlyStalledEpicLoop() {
        var watcher = StallWatcher()
        // 手で止めた・正常に終わった（state が消えた）・動いているループは再開しない
        for status in [
            LoopStatus.idle,
            LoopStatus(stateFileExists: true, processAlive: false),
            LoopStatus(stateFileExists: false, processAlive: true, stalled: true)
        ] {
            #expect(watcher.update(repositoryKey: "r", status: status, snapshot: Self.epic) == nil)
        }
        // epic のブランチでなければ再開しない
        let develop = EpicSnapshot(branch: "develop", goal: nil, state: nil)
        #expect(watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: develop) == nil)

        #expect(watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: Self.epic) == .resume(attempt: 1))
    }

    @Test func givesUpAfterMaxAttemptsWithoutProgressAndCountsAgainOnProgress() {
        var watcher = StallWatcher()
        for attempt in 1...StallWatcher.maxAttempts {
            #expect(watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: Self.epic) == .resume(attempt: attempt))
        }
        let giveUp = watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: Self.epic)
        #expect(giveUp == .giveUp(attempts: StallWatcher.maxAttempts))
        // やめたことは 1 回だけ伝える
        #expect(watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: Self.epic) == nil)

        // ループが進んだ（state が変わった）ら数え直す
        let progressed = EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: "## メモ\n- #1 を作成\n")
        #expect(watcher.update(repositoryKey: "r", status: Self.stalled, snapshot: progressed) == .resume(attempt: 1))
        // リポジトリごとに数える
        #expect(watcher.update(repositoryKey: "other", status: Self.stalled, snapshot: Self.epic) == .resume(attempt: 1))
    }

    @Test func epicIsInProgressOnlyWhenPreparedWithUnfinishedTasks() {
        let goal = "- [x] 【FEAT】A\n- [ ] 【FEAT】B"
        #expect(EpicSnapshot(branch: "epic/mvp", goal: goal, state: nil, loopPrepared: true).inProgress)
        // 準備の途中（完了語が無い）・epic 以外のブランチ・回答待ちだけが残った epic は途中とみなさない
        #expect(!EpicSnapshot(branch: "epic/mvp", goal: goal, state: nil).inProgress)
        #expect(!EpicSnapshot(branch: "develop", goal: goal, state: nil, loopPrepared: true).inProgress)
        let waiting = "- [x] 【FEAT】A\n- [ ] 【FEAT】B  ※回答待ち（PR #3 / ask id 1）"
        #expect(!EpicSnapshot(branch: "epic/mvp", goal: waiting, state: nil, loopPrepared: true).inProgress)
        #expect(!EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil, loopPrepared: true).inProgress)
    }
}
