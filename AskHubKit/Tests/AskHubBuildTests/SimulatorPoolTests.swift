@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

struct SimulatorPoolTests {
    static let tools = BuildTools(home: URL(fileURLWithPath: "/Users/me"), temporaryDirectory: URL(fileURLWithPath: "/tmp/askhub-worker"))
    static let iPhone = SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")

    /// 人が作った Simulator（`askhub-` で始まるものを含む）
    static let humanDevices = [
        FakeSimctl.Device(udid: uuid(1), name: "iPhone 17 Pro", runtime: FakeSimctl.iOS270, deviceType: FakeSimctl.iPhone17Pro),
        FakeSimctl.Device(
            udid: uuid(2), name: "askhub-anim-a", runtime: FakeSimctl.iOS265, deviceType: FakeSimctl.iPhone17Pro, state: "Booted"
        ),
        FakeSimctl.Device(udid: uuid(3), name: "askhub-12mini", runtime: FakeSimctl.iOS270, deviceType: FakeSimctl.iPhone17Pro)
    ]

    /// 数字 1 文字を並べた UDID
    static func uuid(_ digit: Int) -> String {
        let part = { (count: Int) in String(repeating: String(digit), count: count) }
        return [part(8), part(4), part(4), part(4), part(12)].joined(separator: "-")
    }

    private func pool(_ simctl: FakeSimctl) -> (SimulatorPool, FakeCommands) {
        let runner = FakeCommands { simctl.respond(to: $0) }
        return (SimulatorPool(tools: Self.tools, runner: runner), runner)
    }

    @Test func namesSlotsAndTellsWorkerSimulatorsApart() {
        let name = SimulatorPool.name(slot: 1, deviceType: "iPad Pro 13-inch (M5)", platform: .iOS, runtimeVersion: "26.5")
        #expect(name == "askhub-worker-1-iPad-Pro-13-inch-M5-iOS-26.5")
        #expect(SimulatorPool.isWorkerName(name))
        #expect(SimulatorPool.isWorkerName("askhub-worker-12-iPhone-17-Pro-iOS-27.0"))
        // 人が作ったもの（`askhub-` で始まっていても）は、ワーカーのものとみなさない
        let humans = [
            "askhub-anim-a", "askhub-12mini", "askhub-worker-", "askhub-worker-x-iPhone", "askhub-worker-1-iPhone 17", "iPhone 17 Pro"
        ]
        for human in humans {
            #expect(!SimulatorPool.isWorkerName(human), "\(human)")
        }
    }

    @Test func createsBootsAndReusesTheSlotSimulator() async throws {
        let simctl = FakeSimctl(devices: Self.humanDevices)
        let (pool, runner) = pool(simctl)
        let first = try await pool.prepare(slot: 1, for: Self.iPhone)
        // OS の版の指定が無ければ、SDK（27.0）と同じか古いランタイムのうち最新
        #expect(first.name == "askhub-worker-1-iPhone-17-Pro-iOS-27.0")
        #expect(first.runtime == FakeSimctl.iOS270)
        #expect(first.state == "Booted")
        #expect(runner.arguments.contains(["simctl", "create", first.name, FakeSimctl.iPhone17Pro, FakeSimctl.iOS270]))
        #expect(runner.arguments.contains(["simctl", "bootstatus", first.udid, "-b"]))

        let again = try await pool.prepare(slot: 1, for: Self.iPhone)
        #expect(again.udid == first.udid)
        #expect(runner.arguments.filter { $0.dropFirst().first == "create" }.count == 1)
        // 人が作ったものには触れない
        #expect(simctl.current.filter { !SimulatorPool.isWorkerName($0.name) } == Self.humanDevices)
    }

    @Test func choosesTheRequestedRuntimeAndDeviceTypeIdentifier() async throws {
        let simctl = FakeSimctl()
        let (pool, runner) = pool(simctl)
        let destination = SimulatorDestination(platform: .iOS, deviceType: FakeSimctl.iPadPro13, osVersion: "26.5")
        let simulator = try await pool.prepare(slot: 2, for: destination)
        #expect(simulator.name == "askhub-worker-2-iPad-Pro-13-inch-M5-iOS-26.5")
        #expect(simulator.runtime == FakeSimctl.iOS265)
        // 版を指定したときは SDK の版を見ない
        #expect(!runner.arguments.contains { $0.first == "--sdk" })

        let vision = try await pool.prepare(slot: 0, for: SimulatorDestination(platform: .visionOS, deviceType: "Apple Vision Pro"))
        #expect(vision.name == "askhub-worker-0-Apple-Vision-Pro-visionOS-26.5")
        #expect(runner.arguments.contains(["--sdk", "xrsimulator", "--show-sdk-version"]))
    }

    @Test func reportsMissingRuntimesAndDeviceTypes() async {
        let (pool, _) = pool(FakeSimctl())
        await #expect(throws: SimulatorError("iOS 25.0 のランタイムが入っていない")) {
            try await pool.prepare(slot: 1, for: SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "25.0"))
        }
        await #expect(throws: SimulatorError("iOS 27.1 のランタイムに機種「iPhone 17 Pro」が無い")) {
            try await pool.prepare(slot: 1, for: SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "27.1"))
        }
        await #expect(throws: SimulatorError("枠の番号が正しくない（-1）")) {
            try await pool.prepare(slot: -1, for: Self.iPhone)
        }
    }

    @Test func recreatesBrokenSimulatorsWithTheSameName() async throws {
        let name = "askhub-worker-1-iPhone-17-Pro-iOS-27.0"
        let broken = [
            // ランタイムを消した後のもの
            FakeSimctl.Device(
                udid: Self.uuid(4), name: name, runtime: FakeSimctl.iOS270, deviceType: FakeSimctl.iPhone17Pro, isAvailable: false
            ),
            // 機種が違うもの
            FakeSimctl.Device(udid: Self.uuid(5), name: name, runtime: FakeSimctl.iOS270, deviceType: FakeSimctl.iPhone18Pro)
        ]
        let simctl = FakeSimctl(devices: broken)
        let (pool, runner) = pool(simctl)
        let simulator = try await pool.prepare(slot: 1, for: Self.iPhone)
        #expect(!broken.map(\.udid).contains(simulator.udid))
        #expect(simctl.current.map(\.udid) == [simulator.udid])
        #expect(runner.arguments.contains(["simctl", "delete", Self.uuid(4)]))
    }

    @Test func erasesAndShutsDownOnlyWorkerSimulators() async throws {
        let simctl = FakeSimctl(devices: Self.humanDevices)
        let (pool, runner) = pool(simctl)
        let simulator = try await pool.prepare(slot: 1, for: Self.iPhone)
        try await pool.erase(simulator)
        #expect(runner.arguments.suffix(2) == [["simctl", "shutdown", simulator.udid], ["simctl", "erase", simulator.udid]])
        // 止まっているものを止めても失敗にしない
        try await pool.shutdown(simulator)

        let human = Simulator(udid: Self.humanDevices[1].udid, name: "askhub-anim-a", runtime: FakeSimctl.iOS265, state: "Booted")
        let before = runner.commands.count
        await #expect(throws: SimulatorError.self) { try await pool.erase(human) }
        await #expect(throws: SimulatorError.self) { try await pool.shutdown(human) }
        await #expect(throws: SimulatorError.self) { try await pool.delete(human) }
        #expect(runner.commands.count == before)
    }

    @Test func removesStraySimulatorsButNotHumanOnes() async throws {
        let simctl = FakeSimctl(devices: Self.humanDevices)
        let (pool, _) = pool(simctl)
        let kept = try await pool.prepare(slot: 1, for: Self.iPhone)
        let stray = try await pool.prepare(slot: 2, for: Self.iPhone)
        let old = try await pool.prepare(slot: 1, for: SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "26.5"))

        let sweep = try await pool.removeStray(keeping: [kept.name])
        #expect(Set(sweep.removed.map(\.udid)) == [stray.udid, old.udid])
        #expect(sweep.failures.isEmpty)
        #expect(Set(simctl.current.map(\.name)) == Set(Self.humanDevices.map(\.name) + [kept.name]))
    }

    @Test func reportsBootFailuresWithoutSecrets() async {
        let token = "ghp_" + String(repeating: "b", count: 36)
        let simctl = FakeSimctl(bootResult: .failure(1, "Unable to boot device in current state\nAuthorization: \(token)"))
        let (pool, _) = pool(simctl)
        do throws(SimulatorError) {
            _ = try await pool.prepare(slot: 1, for: Self.iPhone)
            Issue.record("起動に失敗したのに投げなかった")
        } catch {
            #expect(error.message == "askhub-worker-1-iPhone-17-Pro-iOS-27.0 を起動できない（終了コード 1）")
            #expect(error.log?.contains("Unable to boot") == true)
            #expect(error.log?.contains(token) == false)
        }
    }

    @Test func reportsTimeouts() async {
        let simctl = FakeSimctl(bootResult: CommandResult(status: 2, standardOutput: Data(), standardError: Data(), timedOut: true))
        let (pool, _) = pool(simctl)
        await #expect(throws: SimulatorError("askhub-worker-1-iPhone-17-Pro-iOS-27.0 を起動できない（時間内に終わらない）")) {
            try await pool.prepare(slot: 1, for: Self.iPhone)
        }
    }

    @Test func runsXcrunWithAFreshEnvironment() async throws {
        let (pool, runner) = pool(FakeSimctl())
        _ = try await pool.prepare(slot: 1, for: Self.iPhone)
        for command in runner.commands {
            #expect(command.executable.path == "/usr/bin/xcrun")
            #expect(command.environment == Self.tools.environment)
            #expect(command.workingDirectory.path == "/tmp/askhub-worker")
        }
        #expect(Set(Self.tools.environment.keys) == [
            "PATH", "HOME", "TMPDIR", "LANG", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT"
        ])
        var tools = Self.tools
        tools.developerDirectory = URL(fileURLWithPath: "/Applications/Xcode-26.6.0.app/Contents/Developer")
        #expect(tools.environment["DEVELOPER_DIR"] == "/Applications/Xcode-26.6.0.app/Contents/Developer")
    }

    @Test func comparesVersions() {
        #expect(SimulatorCatalog.compare("26.5", "27.0") == .orderedAscending)
        #expect(SimulatorCatalog.compare("27.0", "27") == .orderedSame)
        #expect(SimulatorCatalog.compare("26.10", "26.9") == .orderedDescending)
        #expect(SimulatorCatalog.compare("26.5.1", "26.5") == .orderedDescending)
    }
}
