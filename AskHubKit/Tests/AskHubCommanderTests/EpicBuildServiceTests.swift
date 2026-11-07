import AskHubBuild
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

struct EpicBuildServiceTests {
    static let epic = ULID(rawValue: "01JCJ0A0000000000000000001")!

    static func run(_ failure: BuildFailureKind?, summary: String = "…", report: BuildReport = BuildReport()) -> BuildRun {
        let outcome = BuildOutcome(failure: failure, summary: summary, report: report)
        return BuildRun(kind: .testLight, results: [DestinationOutcome(destination: .macOS, outcome: outcome)])
    }

    @Test func mapsBuildResultsForClaude() async {
        let passed = EpicBuildService { _ throws(CancellationError) in Self.run(nil, summary: "テストが通った（全 12 件）") }
        #expect(await passed.run(.testLight, timeout: .seconds(60)) == .passed(summary: "macOS: テストが通った（全 12 件）"))

        // ビルドとテストの失敗は Claude に直させる。トークンらしい文字列は伏せる
        let report = BuildReport(errors: [BuildIssue(message: "cannot find 'x' in scope ghp_abcdefghijklmnopqrstuvwxyz0123")])
        let failed = EpicBuildService { kind throws(CancellationError) in
            #expect(kind == .build)
            return Self.run(.build, summary: "ビルドが通らない", report: report)
        }
        guard case let .failed(summary) = await failed.run(.build, timeout: .seconds(60)) else { Issue.record("落ちたにならない"); return }
        #expect(summary.contains("cannot find 'x' in scope"))
        #expect(!summary.contains("ghp_"))

        // 環境の不調は Claude に渡さず、試行の失敗にする
        let broken = EpicBuildService { _ throws(CancellationError) in Self.run(.environment, summary: "Simulator を起動できない") }
        guard case let .couldNotRun(failure) = await broken.run(.testFull, timeout: .seconds(60)) else { Issue.record("流せないにならない"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(failure.message == "macOS: Simulator を起動できない")
    }

    /// 本物の `ProcessCommandRunner` で、`xcodebuild` の代わりに子プロセスを残して待つスクリプトを流す
    @Test func stopsBuildAndDescendantsWhenTaskTimeRunsOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EpicBuildServiceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let pids = root.appendingPathComponent("child.pid")
        let xcrun = root.appendingPathComponent("xcrun")
        // 後ろで動かした子の sleep は SIGINT を無視する（sh がそうする）ので、SIGTERM で止まる。残れば defer で止める
        try "#!/bin/sh\n/bin/sleep 120 & echo $! > '\(pids.path)'; wait\n".write(to: xcrun, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        let machine = BuildMachine(
            tools: BuildTools(xcrun: xcrun, temporaryDirectory: temporary),
            directories: BuildDirectories(root: root.appendingPathComponent("builds")),
            runner: ProcessCommandRunner()
        )
        let settings = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        let builder = EpicBuilder(machine: machine, settings: settings, epic: Self.epic, sourceDirectory: root, slot: 0)

        let started = ContinuousClock.now
        let result = await EpicBuildService(builder: builder).run(.build, timeout: .seconds(3))
        let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGKILL) }
        guard case let .couldNotRun(failure) = result else { Issue.record("\(result)"); return }
        #expect(failure.failureClass == .timeout)
        // 種類ごとの上限（30 分）ではなく、渡した残りの時間で止まる
        #expect(ContinuousClock.now - started < .seconds(60))
        #expect(await Self.waitUntil { kill(child, 0) != 0 })
    }

    @Test func lendsEachSlotToOneJobAtATime() async {
        let slots = BuildSlots(count: 2)
        let first = await slots.acquire()
        let second = await slots.acquire()
        #expect(first == 0 && second == 1)
        let waiting = Task { await slots.acquire() }
        // 待つ側が並んでから返し、返した枠が待つ側に引き継がれることを確かめる
        while await slots.waiting == 0 {
            await Task.yield()
        }
        await slots.release(1)
        #expect(await waiting.value == 1)
        await slots.release(0)
        #expect(await slots.withSlot { $0 } == 0)
    }

    static func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
