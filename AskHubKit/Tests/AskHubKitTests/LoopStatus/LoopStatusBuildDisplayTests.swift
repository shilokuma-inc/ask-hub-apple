@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusBuildDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func describesRunningBuilds() {
        let moved = LoopStatusBuild(
            slot: "a",
            action: "build",
            host: "macbookpro-m4max",
            attempt: 2,
            moves: [LoopStatusBuildMove(from: "macbookpro-m1pro", to: "macbookpro-m4max", reason: .disconnected)]
        )
        #expect(moved.rowText == "ビルド中 a: macbookpro-m4max（2 回目・macbookpro-m1pro から移動）")

        let twice = LoopStatusBuild(
            slot: "b",
            action: "test",
            attempt: 3,
            moves: [LoopStatusBuildMove(from: "m1", to: "m2", reason: .disconnected), LoopStatusBuildMove(from: "m2", reason: .noPlatform)]
        )
        // 移動の直後は Mac が決まっていない
        #expect(twice.rowText == "テスト中 b: Mac の空き待ち（3 回目・m2 から移動・移動 2 回）")

        #expect(LoopStatusBuild(slot: "a", action: "archive", host: "local").rowText == "archive中 a: local")
    }

    @Test func describesFinishedBuilds() {
        let succeeded = LoopStatusBuild(slot: "b", action: "test", host: "local", attempt: 1, exitCode: 0)
        #expect(succeeded.rowText == "直近のテスト b: 成功・local（1 回目）")
        #expect(LoopStatusBuild(slot: "a", action: "build", host: "m1", exitCode: 65).rowText == "直近のビルド a: 失敗（終了コード 65）・m1")
        // どこでも動かなかった・終了コードが分からない
        #expect(LoopStatusBuild(slot: "a", action: "build", exitCode: 75).rowText == "直近のビルド a: 失敗（終了コード 75）")
        #expect(LoopStatusBuild(slot: "a", action: "build", finishedAt: now).rowText == "直近のビルド a: 終了")
    }

    @Test func showsOneLinePerSlotPreferringRunningBuild() {
        let builds = LoopStatusBuilds(
            running: [LoopStatusBuild(slot: "b", action: "build", host: "m4", attempt: 1)],
            latest: [
                LoopStatusBuild(slot: "b", action: "test", host: "m4", exitCode: 0),
                LoopStatusBuild(slot: "a", action: "test", host: "m1", exitCode: 1)
            ],
            moved: [
                LoopStatusBuild(
                    slot: "a", action: "build", host: "m1", moves: [LoopStatusBuildMove(from: "m2", reason: .disconnected)], exitCode: 0
                )
            ]
        )
        #expect(builds.rowTexts == ["直近のテスト a: 失敗（終了コード 1）・m1", "ビルド中 b: m4（1 回目）"])
        #expect(LoopStatusBuilds().rowTexts.isEmpty)
    }

    @Test func rowDisplayCarriesBuildsWithoutCountingThemAsAbnormal() {
        let failed = LoopStatusBuilds(latest: [LoopStatusBuild(slot: "a", action: "build", host: "m1", exitCode: 65)])
        let row = LoopStatusRow(
            repository: "o/r",
            report: LoopStatusReport(state: .running, lastActivityAt: now, checkedAt: now, builds: failed),
            lastSeen: now
        )
        #expect(row.display(now: now).buildTexts == ["直近のビルド a: 失敗（終了コード 65）・m1"])
        // ビルドの失敗はバッジ（異常）に数えない
        #expect(!row.isAbnormal(now: now))

        let plain = LoopStatusRow(repository: "o/r", report: LoopStatusReport(state: .running, checkedAt: now), lastSeen: now)
        #expect(plain.display(now: now).buildTexts.isEmpty)
        // 担当 PC がいなければ出さない
        let stale = LoopStatusRow(
            repository: "o/r", report: LoopStatusReport(state: .running, checkedAt: now.addingTimeInterval(-3600), builds: failed)
        )
        #expect(stale.display(now: now).buildTexts.isEmpty)
    }
}
