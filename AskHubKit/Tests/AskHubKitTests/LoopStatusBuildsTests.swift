@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusBuildsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var builds: LoopStatusBuilds {
        LoopStatusBuilds(
            running: [
                .init(
                    slot: "a",
                    action: "build",
                    platform: "iOS",
                    host: "macbookpro-m4max",
                    attempt: 2,
                    moves: [
                        .init(from: "macbookpro-m1pro", to: "macbookpro-m4max", reason: .disconnected, movedAt: now.addingTimeInterval(-60))
                    ],
                    startedAt: now.addingTimeInterval(-300)
                )
            ],
            latest: [
                .init(
                    slot: "b",
                    action: "test",
                    platform: "macOS",
                    host: "local",
                    attempt: 1,
                    exitCode: 0,
                    seconds: 95,
                    startedAt: now.addingTimeInterval(-900),
                    finishedAt: now.addingTimeInterval(-805)
                )
            ],
            moved: [
                .init(
                    slot: "b",
                    action: "build",
                    platform: "iOS",
                    host: nil,
                    attempt: 2,
                    moves: [.init(from: "macmini", reason: .noPlatform, movedAt: now.addingTimeInterval(-7200))],
                    exitCode: 65,
                    seconds: 40,
                    finishedAt: now.addingTimeInterval(-7100)
                )
            ]
        )
    }

    private var report: LoopStatusReport {
        LoopStatusReport(state: .running, epic: "epic/build-hosts", checkedAt: now, builds: builds)
    }

    @Test func roundTripsBuilds() {
        #expect(LoopStatusReport.parse(report.issueBody) == report)
        #expect(LoopStatusReport.parse(report.issueBody)?.builds?.running.first?.moves.first?.to == "macbookpro-m4max")

        let empty = LoopStatusReport(state: .running, checkedAt: now, builds: .init())
        #expect(LoopStatusReport.parse(empty.issueBody) == empty)
        #expect(empty.builds?.isEmpty == true)
    }

    @Test func omitsBuildsKeyWhenUnknown() {
        let plain = LoopStatusReport(state: .running, checkedAt: now)
        #expect(!plain.issueBody.contains("builds"))
        #expect(!plain.issueBody.contains("ビルド"))
    }

    @Test func readsMarkersWithoutBuilds() {
        // ビルドの情報を足す前のオーケストレーターが書いた目印
        let body = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#
        #expect(LoopStatusReport.parse(body)?.builds == nil)
        #expect(LoopStatusReport.parse(body)?.state == .running)
    }

    @Test func readsBuildsWithMissingAndUnknownKeys() throws {
        let body = #"<!-- ask-hub:loop-status {"builds":{"running":[{"action":"build","slot":"a","cpu":3,"#
            + #""moves":[{"from":"m1","reason":"flaky"}]}],"queued":[]},"checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#
        let builds = try #require(LoopStatusReport.parse(body)?.builds)
        #expect(builds.latest.isEmpty)
        #expect(builds.moved.isEmpty)
        let build = try #require(builds.running.first)
        #expect(build.host == nil)
        #expect(build.attempt == nil)
        #expect(!build.isFinished)
        #expect(build.succeeded == nil)
        #expect(build.moves == [.init(from: "m1", reason: .unknown)])
    }

    @Test func keepsStatusWhenBuildsAreMalformed() {
        // ビルドの情報だけが崩れていても、状態は読める
        let body = #"<!-- ask-hub:loop-status {"builds":{"running":[{"host":"m1"}]},"#
            + #""checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#
        let parsed = LoopStatusReport.parse(body)
        #expect(parsed?.state == .running)
        #expect(parsed?.builds == nil)
    }

    @Test func writesReadableRows() {
        let body = report.issueBody
        #expect(body.contains(
            "| ビルド中 | a: build（iOS） macbookpro-m4max・2 回目（macbookpro-m1pro から移動: 切断）・2027-01-15T07:55:00Z |"
        ))
        #expect(body.contains("| 直近のビルド | b: test（macOS） local・1 回目・成功・2027-01-15T07:46:35Z |"))
        #expect(body.contains("| 24 時間の移動 | b: build（iOS） Mac なし・2 回目（macmini から移動: ビルド環境なし）・失敗・2027-01-15T06:01:40Z |"))
        // 行は確認時刻の前に置く
        let checkedAt = body.range(of: "| 確認時刻 |")?.lowerBound
        let running = body.range(of: "| ビルド中 |")?.lowerBound
        #expect(running != nil && checkedAt != nil && running! < checkedAt!)
    }

    @Test func joinsSeveralBuildsInOneCell() {
        var report = report
        report.builds?.running.append(.init(slot: "b", action: "test", host: "macbookpro-m1pro", attempt: 1))
        #expect(report.issueBody.contains("・2027-01-15T07:55:00Z<br>b: test macbookpro-m1pro・1 回目 |"))
    }

    @Test func escapesTableCells() {
        let build = LoopStatusBuild(slot: "a", action: "build|x\ny", host: "m|1")
        #expect(build.tableText == #"a: build\|x y m\|1"#)
    }

    @Test func comparesBuildsAsStatus() {
        var later = report
        later.checkedAt = now.addingTimeInterval(600)
        #expect(report.hasSameStatus(as: later))

        later.builds?.running[0].attempt = 3
        #expect(!report.hasSameStatus(as: later))
    }

    @Test func truncatesFractionalSeconds() {
        var build = LoopStatusBuild(slot: "a", action: "build", startedAt: now.addingTimeInterval(0.6))
        #expect(build.startedAt == now)
        build.finishedAt = now.addingTimeInterval(10.9)
        #expect(build.finishedAt == now.addingTimeInterval(10))

        var move = LoopStatusBuildMove(from: "m1", reason: .disconnected, movedAt: now.addingTimeInterval(0.2))
        #expect(move.movedAt == now)
        move.movedAt = now.addingTimeInterval(5.5)
        #expect(move.movedAt == now.addingTimeInterval(5))

        let report = LoopStatusReport(
            state: .running,
            checkedAt: now,
            builds: .init(running: [.init(slot: "a", action: "build", moves: [move], startedAt: now.addingTimeInterval(0.6))])
        )
        #expect(LoopStatusReport.parse(report.issueBody) == report)
    }

    @Test func bodyHoldsNoLocalPaths() {
        let body = report.issueBody
        #expect(!body.contains("/Users/"))
        #expect(!body.contains("path"))
        #expect(!body.contains("ralph-a"))
    }
}
