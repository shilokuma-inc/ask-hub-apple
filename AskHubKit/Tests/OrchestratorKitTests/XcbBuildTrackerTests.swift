import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct XcbBuildTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repository = "shilokuma-inc/ask-hub-apple"

    private func tracker() -> XcbBuildTracker {
        XcbBuildTracker { path in
            switch path {
            case "/src/app-ralph-a": (repository: "shilokuma-inc/ask-hub-apple", slot: "a")
            case "/src/app-ralph-b": (repository: "shilokuma-inc/ask-hub-apple", slot: "b")
            case "/src/other-ralph-a": (repository: "shilokuma-inc/other", slot: "a")
            default: nil
            }
        }
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func started(_ id: String, path: String = "/src/app-ralph-a", action: String = "build", _ seconds: TimeInterval) -> XcbEvent {
        XcbEvent(time: at(seconds), kind: .jobStarted(.init(id: id, path: path, action: action, platform: "iOS")))
    }

    private func attempt(_ id: String, _ host: String, _ number: Int, _ seconds: TimeInterval) -> XcbEvent {
        XcbEvent(time: at(seconds), kind: .jobAttempt(id: id, host: host, attempt: number))
    }

    private func finished(_ id: String, host: String?, rc: Int, moves: Int = 0, _ seconds: TimeInterval) -> XcbEvent {
        let finished = XcbEvent.Finished(
            id: id,
            path: "/src/app-ralph-a",
            action: "build",
            platform: "iOS",
            host: host,
            exitCode: rc,
            seconds: 60,
            attempts: 1,
            moves: moves
        )
        return XcbEvent(time: at(seconds), kind: .jobFinished(finished))
    }

    @Test func tracksRunningJobAcrossMoves() {
        var tracker = tracker()
        tracker.apply([
            started("j1", 0),
            attempt("j1", "m1pro", 1, 1),
            XcbEvent(time: at(30), kind: .jobMoved(id: "j1", from: "m1pro", reason: "disconnected"))
        ])
        // 移動中は Mac が決まっていない
        var running = tracker.builds(for: repository).running
        #expect(running.map(\.host) == [nil])
        #expect(running.first?.moves == [LoopStatusBuildMove(from: "m1pro", reason: .disconnected, movedAt: at(30))])
        #expect(tracker.hostJobs.isEmpty)

        tracker.apply(attempt("j1", "m4max", 2, 31))
        running = tracker.builds(for: repository).running
        let expected = LoopStatusBuild(
            slot: "a",
            action: "build",
            platform: "iOS",
            host: "m4max",
            attempt: 2,
            moves: [LoopStatusBuildMove(from: "m1pro", to: "m4max", reason: .disconnected, movedAt: at(30))],
            startedAt: at(0)
        )
        #expect(running == [expected])
        let job = BuildHostJob(
            host: "m4max", repository: repository, slot: "a", action: "build", platform: "iOS", attempt: 2, startedAt: at(0)
        )
        #expect(tracker.hostJobs == [job])
    }

    @Test func keepsLatestPerSlotAndMovedBuilds() {
        var tracker = tracker()
        tracker.apply([
            started("j1", 0),
            attempt("j1", "m1pro", 1, 1),
            XcbEvent(time: at(30), kind: .jobMoved(id: "j1", from: "m1pro", reason: "no_platform")),
            attempt("j1", "m4max", 2, 31),
            finished("j1", host: "m4max", rc: 0, moves: 1, 90),
            started("j2", path: "/src/app-ralph-b", action: "test", 100),
            attempt("j2", "m4max", 1, 101),
            XcbEvent(time: at(160), kind: .jobFinished(.init(id: "j2", action: "test", host: "m4max", exitCode: 65, moves: 0))),
            started("j3", 200),
            attempt("j3", "m4max", 1, 201),
            finished("j3", host: "m4max", rc: 1, 260)
        ])
        let builds = tracker.builds(for: repository)
        #expect(builds.running.isEmpty)
        // スロットごとに直近の 1 件。a は j1 を j3 が置き換える
        #expect(builds.latest.map(\.slot) == ["a", "b"])
        #expect(builds.latest.map(\.exitCode) == [1, 65])
        #expect(builds.latest.last?.startedAt == at(100))
        // 移動のあったビルドは残る
        #expect(builds.moved.count == 1)
        #expect(builds.moved.first?.moves.first?.reason == .noPlatform)
        #expect(builds.moved.first?.finishedAt == at(90))
        #expect(builds.moved.first?.succeeded == true)
    }

    @Test func dropsMovedBuildsAfterRetentionAndLimit() {
        var tracker = tracker()
        for index in 0..<(XcbBuildTracker.movedLimit + 3) {
            let base = TimeInterval(index * 100)
            tracker.apply([
                started("j\(index)", base),
                XcbEvent(time: at(base + 1), kind: .jobMoved(id: "j\(index)", from: "m1pro", reason: "disconnected")),
                finished("j\(index)", host: "m4max", rc: 0, moves: 1, base + 50)
            ])
        }
        tracker.prune(now: at(10_000))
        var moved = tracker.builds(for: repository).moved
        #expect(moved.count == XcbBuildTracker.movedLimit)
        // 新しい順
        #expect(moved.first?.finishedAt == at(TimeInterval((XcbBuildTracker.movedLimit + 2) * 100) + 50))

        tracker.prune(now: at(XcbBuildTracker.movedRetention + 10_000))
        moved = tracker.builds(for: repository).moved
        #expect(moved.isEmpty)
        // 直近の 1 件は 24 時間を過ぎても残す
        #expect(tracker.builds(for: repository).latest.count == 1)
    }

    @Test func ignoresBuildsOutsideLoopSlotsButCountsThemOnHosts() {
        var tracker = tracker()
        tracker.apply([
            started("main", path: "/src/app", 0),
            attempt("main", "m4max", 1, 1),
            started("other", path: "/src/other-ralph-a", 2),
            attempt("other", "m4max", 1, 3)
        ])
        #expect(tracker.builds(for: repository).running.isEmpty)
        #expect(tracker.builds(for: "shilokuma-inc/other").running.map(\.slot) == ["a"])
        #expect(tracker.hostJobs.map(\.repository) == ["shilokuma-inc/other"])
        #expect(tracker.hosts == [BuildHost(name: "m4max", state: .ok, running: 2)])

        tracker.apply(XcbEvent(time: at(10), kind: .jobFinished(.init(id: "main", path: "/src/app", action: "build", exitCode: 0))))
        #expect(tracker.builds(for: repository).latest.isEmpty)
        #expect(tracker.hosts.first?.running == 1)
    }

    @Test func readsFinishedJobsWhoseStartWasNotRead() {
        var tracker = tracker()
        tracker.apply(finished("old", host: nil, rc: 75, 10))
        let latest = tracker.builds(for: repository).latest
        #expect(latest.map(\.slot) == ["a"])
        #expect(latest.first?.host == nil)
        #expect(latest.first?.startedAt == nil)
    }

    @Test func tracksHostStates() {
        var tracker = tracker()
        tracker.apply([
            attempt("x", "local", 1, 0),
            XcbEvent(time: at(1), kind: .hostState(host: "m1pro", state: "down", reason: "接続できない")),
            XcbEvent(time: at(2), kind: .hostState(host: "m4max", state: "down", reason: "Xcode が未準備（/Applications/Xcode.app）")),
            XcbEvent(time: at(3), kind: .hostDrained(host: "mini2"))
        ])
        #expect(tracker.hosts == [
            BuildHost(name: "local", state: .standby, running: 0),
            BuildHost(name: "m1pro", state: .down, reason: .unreachable, running: 0),
            BuildHost(name: "m4max", state: .down, reason: .xcodeNotReady, running: 0),
            BuildHost(name: "mini2", state: .drained, running: 0)
        ])

        tracker.apply([
            XcbEvent(time: at(4), kind: .hostState(host: "m1pro", state: "ok", reason: nil)),
            XcbEvent(time: at(5), kind: .hostState(host: "m4max", state: "down", reason: "実行中に切断")),
            XcbEvent(time: at(6), kind: .hostUndrained(host: "mini2"))
        ])
        #expect(tracker.hosts.map(\.state) == [.standby, .ok, .down, .ok])
        #expect(tracker.hosts.map(\.reason) == [nil, nil, .disconnected, nil])
    }

    @Test func classifiesHostReasonsWithoutKeepingText() {
        #expect(XcbBuildTracker.hostReason("接続できない") == .unreachable)
        #expect(XcbBuildTracker.hostReason("実行中に切断") == .disconnected)
        #expect(XcbBuildTracker.hostReason("Xcode が未準備（xcode-select）") == .xcodeNotReady)
        #expect(XcbBuildTracker.hostReason("ディスクがいっぱい") == .unknown)
        #expect(XcbBuildTracker.hostReason(nil) == .unknown)
    }

    @Test func dropsJobsThatNeverFinish() {
        var tracker = tracker()
        tracker.apply([started("j1", 0), attempt("j1", "m4max", 1, 1)])
        tracker.prune(now: at(XcbBuildTracker.staleJobAge - 1))
        #expect(tracker.builds(for: repository).running.count == 1)
        tracker.prune(now: at(XcbBuildTracker.staleJobAge + 1))
        #expect(tracker.builds(for: repository).running.isEmpty)
        #expect(tracker.hosts.first?.running == 0)
    }

    @Test func countsAttemptsWhenNumberIsMissing() {
        var tracker = tracker()
        tracker.apply([
            started("j1", 0),
            XcbEvent(time: at(1), kind: .jobAttempt(id: "j1", host: "m1pro", attempt: nil)),
            XcbEvent(time: at(2), kind: .jobAttempt(id: "j1", host: "m4max", attempt: nil))
        ])
        #expect(tracker.builds(for: repository).running.first?.attempt == 2)
    }
}
