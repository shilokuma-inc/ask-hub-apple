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
/// - `ASKHUB_LIVE_BUILD_ACTION`: `build` か `test`（既定。子 PR 用のテスト）
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
        let action: BuildAction = LiveBuild.environment["ASKHUB_LIVE_BUILD_ACTION"] == "build" ? .build : .test(.pullRequest)
        let epic = try #require(ULID(rawValue: "01JC0000000000000000000000"))
        let request = BuildRequest(
            settings: settings, action: action, destination: .simulator(simulator), sourceDirectory: project, epic: epic
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
