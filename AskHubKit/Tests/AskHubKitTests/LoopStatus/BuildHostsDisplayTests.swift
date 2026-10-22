@testable import AskHubKit
import Foundation
import Testing

struct BuildHostsDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(checkedMinutesAgo: Double = 3) -> BuildHostsStatus {
        BuildHostsStatus(
            repository: "o/r",
            issueURL: URL(string: "https://github.com/o/r/issues/1")!,
            report: BuildHostsReport(
                hosts: [
                    BuildHost(name: "m4max", state: .ok, cores: 14, load: 3.256, memoryFreePercent: 41, running: 1, slots: 2),
                    BuildHost(name: "m1pro", state: .down, reason: .unreachable, running: 0),
                    BuildHost(name: "local", state: .standby),
                    BuildHost(name: "mini2", state: .drained, memoryFreePercent: 80)
                ],
                jobs: [
                    BuildHostJob(
                        host: "m4max", repository: "shilokuma-inc/ask-hub-apple", slot: "a", action: "build", platform: "iOS", attempt: 2
                    )
                ],
                checkedAt: now.addingTimeInterval(-checkedMinutesAgo * 60)
            )
        )
    }

    @Test func describesEachHost() {
        let hosts = status().hostDisplays
        #expect(hosts.map(\.name) == ["m4max", "m1pro", "local", "mini2"])
        #expect(hosts.map(\.statusText) == ["使える", "切断（接続できない）", "待機", "外している"])
        #expect(hosts.map(\.tone) == [.available, .unavailable, .idle, .idle])
        #expect(hosts[0].loadText == "load 3.26 / 14 コア・空きメモリ 41%")
        #expect(hosts[0].runningText == "実行中 1 / 2")
        #expect(hosts[0].jobTexts == ["ask-hub-apple a: ビルド（iOS）・2 回目"])
        #expect(hosts[1].loadText == nil)
        #expect(hosts[1].runningText == "実行中 0")
        #expect(hosts[1].jobTexts.isEmpty)
        #expect(hosts[2].runningText == nil)
        #expect(hosts[3].loadText == "空きメモリ 80%")
    }

    @Test func showsHostsWithTheSameNameOnce() {
        var status = status()
        status.report.hosts.append(BuildHost(name: "m1pro", state: .ok))
        let hosts = status.hostDisplays
        #expect(hosts.map(\.id) == ["m4max", "m1pro", "local", "mini2"])
        #expect(hosts[1].statusText == "切断（接続できない）")
    }

    @Test func staleWhenNotRewrittenForThirtyMinutes() {
        #expect(!status(checkedMinutesAgo: 29).isStale(now: now))
        #expect(status(checkedMinutesAgo: 31).isStale(now: now))
    }

    @Test func collectsMovesOfAllRepositoriesWithinADay() {
        func row(_ repository: String, moved: [LoopStatusBuild], checkedAt: Date? = nil) -> LoopStatusRow {
            LoopStatusRow(
                repository: repository,
                report: LoopStatusReport(state: .running, checkedAt: checkedAt ?? now, builds: LoopStatusBuilds(moved: moved)),
                lastSeen: checkedAt ?? now
            )
        }
        let twice = LoopStatusBuild(
            slot: "a",
            action: "build",
            host: "local",
            moves: [
                LoopStatusBuildMove(from: "m1", to: "m4", reason: .disconnected),
                LoopStatusBuildMove(from: "m4", to: "local", reason: .noPlatform)
            ],
            exitCode: 65,
            finishedAt: now.addingTimeInterval(-3600)
        )
        let once = LoopStatusBuild(
            slot: "b",
            action: "test",
            host: "m4",
            moves: [LoopStatusBuildMove(from: "m1", to: "m4", reason: .disconnected)],
            exitCode: 0,
            finishedAt: now.addingTimeInterval(-60)
        )
        let old = LoopStatusBuild(slot: "a", action: "build", exitCode: 0, finishedAt: now.addingTimeInterval(-25 * 3600))
        let rows = [
            row("o/a", moved: [twice, old]),
            row("o/b", moved: [once]),
            // 担当 PC がいない行の目印は読まない
            row("o/c", moved: [once], checkedAt: now.addingTimeInterval(-2 * 3600))
        ]
        let moves = LoopStatusRow.buildMoves(in: rows, now: now)
        #expect(moves.map(\.repository) == ["o/b", "o/a"])
        #expect(moves.map(\.text) == ["b: テスト m1 → m4（切断）", "a: ビルド m1 → m4 → local（切断・ビルド環境なし）"])
        #expect(moves.map(\.resultText) == ["成功", "失敗（終了コード 65）"])
        #expect(moves.map(\.succeeded) == [true, false])
    }

    @Test func keepsMovesWithTheSameContentsWithUniqueIDs() {
        // 終わっていない同じ移動（終了日時・試行が無い）が、同じリポジトリの 2 つのループに 1 件ずつある
        let running = LoopStatusBuild(slot: "a", action: "build", host: "m4", moves: [
            LoopStatusBuildMove(from: "m1", to: "m4", reason: .disconnected)
        ])
        let finished = LoopStatusBuild(slot: "b", action: "test", host: "m4", exitCode: 0, finishedAt: now.addingTimeInterval(-60))
        func row(_ repository: String, moved: [LoopStatusBuild]) -> LoopStatusRow {
            LoopStatusRow(
                repository: repository,
                report: LoopStatusReport(state: .running, checkedAt: now, builds: LoopStatusBuilds(moved: moved)),
                lastSeen: now
            )
        }
        let rows = [row("o/a", moved: [finished, running, running]), row("O/A", moved: [running])]
        let moves = LoopStatusRow.buildMoves(in: rows, now: now)
        #expect(moves.count == 4)
        #expect(Set(moves.map(\.id)).count == 4)
        #expect(moves.map(\.occurrence) == [1, 1, 2, 3])
        #expect(moves[1].id == moves[1].contentKey)
        #expect(moves[2].id == moves[1].id + "#2")
        // 同じ並びなら、取り直しても id は変わらない
        #expect(LoopStatusRow.buildMoves(in: rows, now: now).map(\.id) == moves.map(\.id))
    }

    @Test func describesMovedBuildWithoutMoveEvents() {
        // xcb が数えた移動の回数だけがある（移動のイベントを読めていない）
        let build = LoopStatusBuild(slot: "a", action: "build", host: "m4", exitCode: 0, finishedAt: now)
        #expect(build.moveText == "a: ビルド m4（移動あり）")
        #expect(LoopStatusBuild(slot: "a", action: "build").resultText == "実行中")
    }
}
