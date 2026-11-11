#if os(macOS)
@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// 本物の `simctl`・`xcodebuild` に当てる。`ASKHUB_LIVE_BUILD=1` のときだけ動く。作った Simulator は最後に消す。
///
/// - `ASKHUB_LIVE_BUILD_PROJECT`: ビルドする写しのフォルダ。無ければ Simulator の操作だけを確かめる
/// - `ASKHUB_LIVE_BUILD_SETTINGS`: `BuildSettings` の JSON（最初の Simulator の行き先で流す）
/// - `ASKHUB_LIVE_BUILD_KIND`: `build`・`testLight`（既定）・`testFull`
/// - `ASKHUB_LIVE_BUILD_EXPECT`: 期待する結果（`success`（既定）・`build`・`test`・`timeout`・`environment`・`unknown`）
/// - `ASKHUB_LIVE_BUILD_DUMP`: 結果のバンドルの JSON（`build-results`・`test-results summary`）を書き出すフォルダ（テストの見本を作り直すとき）
@Suite(.enabled(if: LiveBuild.isEnabled), .serialized)
struct LiveBuildTests {
    /// 人や動いているワーカーの枠と重ならない番号
    static let slot = 90

    @Test func preparesBuildsAndCleansUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-live-\(UUID().uuidString)")
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = BuildTools(temporaryDirectory: temporary)
        let pool = SimulatorPool(tools: tools, runner: ProcessCommandRunner())
        let settings = try LiveBuild.settings()
        let destination = settings?.destinations.lazy.compactMap { destination -> SimulatorDestination? in
            if case .simulator(let simulator) = destination { return simulator }
            return nil
        }.first ?? SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")

        let simulator = try await pool.prepare(slot: Self.slot, for: destination)
        var failure: (any Error)?
        do {
            try await check(simulator, pool: pool)
            if let settings, let project = LiveBuild.environment["ASKHUB_LIVE_BUILD_PROJECT"] {
                let runner = XcodeBuildRunner(
                    tools: tools, directories: BuildDirectories(root: root.appendingPathComponent("builds")), runner: ProcessCommandRunner()
                )
                try await build(settings, in: URL(fileURLWithPath: project), on: simulator, runner: runner)
            }
            try await pool.erase(simulator)
        } catch {
            failure = error
        }
        // 作った Simulator を消す（ほかの枠のものは残す）
        let others = Set(try await pool.workerSimulators().map(\.name)).subtracting([simulator.name])
        let sweep = try await pool.removeStray(keeping: others)
        #expect(sweep.removed.map(\.udid) == [simulator.udid])
        #expect(try await pool.workerSimulators().allSatisfy { $0.udid != simulator.udid })
        if let failure { throw failure }
    }

    /// Simulator でアプリを起動できない状態にして（SpringBoard を launchd から外す。`Simulator device failed to launch` になり、止めて起動し直すと戻る）、
    /// `EpicBuilder` が Simulator を消去して起動し直し、流し直して通ることを確かめる。
    /// `ASKHUB_LIVE_BUILD_PROJECT`・`ASKHUB_LIVE_BUILD_SETTINGS` が要り、テストの種類（`ASKHUB_LIVE_BUILD_KIND`）で流す。最初の Simulator の行き先だけを使う
    @Test func recoversWhenTheSimulatorCannotLaunchApps() async throws {
        guard let settings = try LiveBuild.settings(), let project = LiveBuild.environment["ASKHUB_LIVE_BUILD_PROJECT"] else { return }
        let kind = LiveBuild.kind
        let destination = settings.destinations.lazy.compactMap { destination -> SimulatorDestination? in
            if case .simulator(let simulator) = destination { return simulator }
            return nil
        }.first
        guard kind.isTest, let destination else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-live-\(UUID().uuidString)")
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = BuildTools(temporaryDirectory: temporary)
        let machine = BuildMachine(
            tools: tools, directories: BuildDirectories(root: root.appendingPathComponent("builds")), runner: ProcessCommandRunner()
        )
        var single = settings
        single.destinations = [.simulator(destination)]
        let epic = try #require(ULID(rawValue: "01JC0000000000000000000000"))
        let source = URL(fileURLWithPath: project)
        let builder = EpicBuilder(machine: machine, settings: single, epic: epic, sourceDirectory: source, slot: Self.slot)

        let simulator = try await machine.pool.prepare(slot: Self.slot, for: destination)
        var failure: (any Error)?
        do {
            let bootout = ["simctl", "spawn", simulator.udid, "launchctl", "bootout", "system/com.apple.SpringBoard"]
            let broken = try await ProcessCommandRunner().run(tools.command(bootout, in: temporary, timeout: .seconds(60)))
            #expect(broken.succeeded, "\(broken.outputText)")
            let run = try await builder.run(kind)
            print("[live] \(run.summary)\n\(run.text())")
            #expect(run.succeeded)
            #expect(run.summary.contains("1 回目は Simulator でアプリかテストの実行役を起動できず"))
        } catch {
            failure = error
        }
        try await machine.pool.delete(simulator)
        if let failure { throw failure }
    }

    /// 前の回の UI テストが端末を横向きにしたまま終わっても、`EpicBuilder` が流す次の UI テストは縦向きで始まることを確かめる。
    /// `ASKHUB_LIVE_BUILD_PROJECT`・`ASKHUB_LIVE_BUILD_SETTINGS` と、横向きにして終わる UI テスト（`ASKHUB_LIVE_BUILD_ROTATE_TEST`）・
    /// 縦向きで始まったかを確かめる UI テスト（`ASKHUB_LIVE_BUILD_PORTRAIT_TEST`）が要る（`-only-testing` の形）。最初の Simulator の行き先だけを使う
    @Test func startsTestsInPortraitAfterALandscapeRun() async throws {
        let environment = LiveBuild.environment
        guard let settings = try LiveBuild.settings(), let project = environment["ASKHUB_LIVE_BUILD_PROJECT"],
              let rotate = environment["ASKHUB_LIVE_BUILD_ROTATE_TEST"], let portrait = environment["ASKHUB_LIVE_BUILD_PORTRAIT_TEST"],
              let destination = settings.destinations.lazy.compactMap({ destination -> SimulatorDestination? in
                  if case .simulator(let simulator) = destination { return simulator }
                  return nil
              }).first else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-live-\(UUID().uuidString)")
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = BuildTools(temporaryDirectory: temporary)
        let machine = BuildMachine(
            tools: tools, directories: BuildDirectories(root: root.appendingPathComponent("builds")), runner: ProcessCommandRunner()
        )
        let epic = try #require(ULID(rawValue: "01JC0000000000000000000000"))
        let source = URL(fileURLWithPath: project)
        func only(_ test: String) -> BuildSettings {
            var single = settings
            single.destinations = [.simulator(destination)]
            single.testLight = TestSelection(onlyTesting: [test])
            return single
        }
        func builder(_ test: String) -> EpicBuilder {
            EpicBuilder(machine: machine, settings: only(test), epic: epic, sourceDirectory: source, slot: Self.slot)
        }

        var failure: (any Error)?
        do {
            let rotated = try await builder(rotate).run(.testLight)
            print("[live] 横向きにする: \(rotated.summary)")
            #expect(rotated.succeeded)
            // 起動し直さずに流すと、横向きのまま始まって落ちる（直す前のワーカーと同じ）
            let simulator = try await machine.pool.prepare(slot: Self.slot, for: destination)
            let request = BuildRequest(
                settings: only(portrait), kind: .testLight, destination: .simulator(simulator), sourceDirectory: source, epic: epic
            )
            let stale = try await machine.runner.run(request, timeout: .seconds(20 * 60))
            print("[live] 起動し直さずに流す: \(stale.summary)\n\(stale.report.text())")
            #expect(stale.failure == .test)
            // EpicBuilder はテストの前に起動し直すので、縦向きで始まる
            let fresh = try await builder(portrait).run(.testLight)
            print("[live] EpicBuilder で流す: \(fresh.summary)\n\(fresh.text())")
            #expect(fresh.succeeded)
        } catch {
            failure = error
        }
        let prefix = "\(SimulatorPool.namePrefix)\(Self.slot)-"
        for simulator in try await machine.pool.workerSimulators() where simulator.name.hasPrefix(prefix) {
            try await machine.pool.delete(simulator)
        }
        if let failure { throw failure }
    }

    private func check(_ simulator: Simulator, pool: SimulatorPool) async throws {
        #expect(SimulatorPool.isWorkerName(simulator.name))
        #expect(UUID(uuidString: simulator.udid) != nil)
        let listed = try await pool.workerSimulators().first { $0.udid == simulator.udid }
        #expect(listed?.state == "Booted")
        // 2 回目は同じものを使い回す
        let destination = try await LiveBuild.destination(of: simulator, in: pool)
        let again = try await pool.prepare(slot: Self.slot, for: try #require(destination))
        #expect(again.udid == simulator.udid)
    }

    private func build(_ settings: BuildSettings, in project: URL, on simulator: Simulator, runner: XcodeBuildRunner) async throws {
        let kind = LiveBuild.kind
        let epic = try #require(ULID(rawValue: "01JC0000000000000000000000"))
        let request = BuildRequest(
            settings: settings, kind: kind, destination: .simulator(simulator), sourceDirectory: project, epic: epic
        )
        let outcome = try await runner.run(request, timeout: .seconds(30 * 60))
        print("[live] \(outcome.summary)\n\(outcome.report.text())")
        let expected = LiveBuild.environment["ASKHUB_LIVE_BUILD_EXPECT"] ?? "success"
        #expect((outcome.failure?.rawValue ?? "success") == expected)
        #expect(outcome.resultBundle != nil)
        if let dump = LiveBuild.environment["ASKHUB_LIVE_BUILD_DUMP"], let bundle = outcome.resultBundle {
            for (name, arguments) in [("build-results", ["get", "build-results"]), ("test-results", ["get", "test-results", "summary"])] {
                let command = runner.tools.command(
                    ["xcresulttool"] + arguments + ["--path", bundle.path], in: project, timeout: .seconds(120)
                )
                let result = try await ProcessCommandRunner().run(command)
                let file = URL(fileURLWithPath: dump).appendingPathComponent("\(expected)-\(name).json")
                try result.standardOutput.write(to: file)
            }
        }
    }
}

enum LiveBuild {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { environment["ASKHUB_LIVE_BUILD"] == "1" }

    static var kind: BuildKind { environment["ASKHUB_LIVE_BUILD_KIND"].flatMap(BuildKind.init(rawValue:)) ?? .testLight }

    static func settings() throws -> BuildSettings? {
        guard let json = environment["ASKHUB_LIVE_BUILD_SETTINGS"] else { return nil }
        return try JSONDecoder().decode(BuildSettings.self, from: Data(json.utf8))
    }

    /// 作った Simulator と同じ行き先（版を固定する）
    static func destination(of simulator: Simulator, in pool: SimulatorPool) async throws -> SimulatorDestination? {
        let catalog = try await pool.list()
        guard let runtime = catalog.runtimes.first(where: { $0.identifier == simulator.runtime }),
              let platform = SimulatorPlatform.allCases.first(where: { $0.runtimePlatform == runtime.platform }),
              let device = catalog.devices[runtime.identifier]?.first(where: { $0.udid == simulator.udid }),
              let type = runtime.supportedDeviceTypes?.first(where: { $0.identifier == device.deviceTypeIdentifier }) else {
            return nil
        }
        return SimulatorDestination(platform: platform, deviceType: type.name, osVersion: runtime.version)
    }
}
#endif
