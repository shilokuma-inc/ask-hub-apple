import AskHubCommands
import Foundation
import os

/// 受け取ったコマンドを記録し、`respond` の結果を返す
final class FakeCommands: CommandRunning {
    private let recorded = OSAllocatedUnfairLock<[Command]>(initialState: [])
    private let respond: @Sendable (Command) -> CommandResult

    init(_ respond: @escaping @Sendable (Command) -> CommandResult) {
        self.respond = respond
    }

    var commands: [Command] { recorded.withLock { $0 } }

    /// `xcrun` の後の引数（`simctl list -j` なら `["simctl", "list", "-j"]`）
    var arguments: [[String]] { commands.map(\.arguments) }

    func run(_ command: Command) async throws -> CommandResult {
        recorded.withLock { $0.append(command) }
        return respond(command)
    }
}

extension CommandResult {
    static func output(_ text: String) -> CommandResult {
        CommandResult(status: 0, standardOutput: Data(text.utf8), standardError: Data())
    }

    static func failure(_ status: Int32, _ text: String) -> CommandResult {
        CommandResult(status: status, standardOutput: Data(), standardError: Data(text.utf8))
    }
}

/// `xcodebuild` を流すたびに、決めた順に結果を返す（使い切ったら最後のものを繰り返す）。結果のバンドルのフォルダを作り、
/// `xcresulttool` には、最後に流した回の結果のバンドルの中身（`build-results`・`test-results summary` の JSON。nil なら読めない）を返す
final class FakeXcodebuild: Sendable {
    struct Run: Sendable {
        var result: CommandResult
        var build: String?
        var tests: String?
    }

    private let runs: [Run]
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(_ runs: [Run]) {
        precondition(!runs.isEmpty)
        self.runs = runs
    }

    /// 流した回数
    var runCount: Int { count.withLock { $0 } }

    func respond(to command: Command) -> CommandResult {
        let arguments = command.arguments
        switch arguments.prefix(3) {
        case ["xcresulttool", "get", "build-results"]:
            return latest.build.map(CommandResult.output) ?? .failure(1, "")
        case ["xcresulttool", "get", "test-results"]:
            return latest.tests.map(CommandResult.output) ?? .failure(1, "")
        default:
            if let index = arguments.firstIndex(of: "-resultBundlePath"), arguments.indices.contains(index + 1) {
                try? FileManager.default.createDirectory(atPath: arguments[index + 1], withIntermediateDirectories: true)
            }
            count.withLock { $0 += 1 }
            return latest.result
        }
    }

    private var latest: Run { runs[min(max(runCount, 1), runs.count) - 1] }
}

/// `xcrun simctl` の振る舞いをまねる（一覧・作成・起動・停止・消去・削除と、SDK の版）
final class FakeSimctl: Sendable {
    struct Device: Equatable, Sendable {
        var udid: String
        var name: String
        var runtime: String
        var deviceType: String
        var state = "Shutdown"
        var isAvailable = true
    }

    static let iOS265 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    static let iOS270 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    static let iOS271 = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"
    static let xrOS265 = "com.apple.CoreSimulator.SimRuntime.xrOS-26-5"
    static let iPhone17Pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    static let iPhone18Pro = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
    static let iPadPro13 = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"
    static let visionPro = "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro"

    private let devices: OSAllocatedUnfairLock<[Device]>
    /// 起動（`bootstatus`）の結果を差し替える
    private let bootResult: CommandResult?
    /// 消去（`erase`）の結果を差し替える
    private let eraseResult: CommandResult?
    let sdkVersion: String

    init(devices: [Device] = [], sdkVersion: String = "27.0", bootResult: CommandResult? = nil, eraseResult: CommandResult? = nil) {
        self.devices = OSAllocatedUnfairLock(initialState: devices)
        self.sdkVersion = sdkVersion
        self.bootResult = bootResult
        self.eraseResult = eraseResult
    }

    var current: [Device] { devices.withLock { $0 } }

    func respond(to command: Command) -> CommandResult {
        let arguments = command.arguments
        if arguments.first == "--sdk" { return .output(sdkVersion + "\n") }
        guard arguments.first == "simctl", arguments.count >= 2 else { return .failure(64, "unknown") }
        let udid = arguments.count >= 3 ? arguments[2] : ""
        switch arguments[1] {
        case "list": return .output(listJSON())
        case "create": return create(name: arguments[2], deviceType: arguments[3], runtime: arguments[4])
        case "bootstatus": return bootResult ?? update(udid) { $0.state = "Booted" }
        case "shutdown":
            guard current.first(where: { $0.udid == udid })?.state != "Shutdown" else {
                return .failure(
                    149,
                    "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\n"
                        + "Unable to shutdown device in current state: Shutdown"
                )
            }
            return update(udid) { $0.state = "Shutdown" }
        case "erase": return eraseResult ?? update(udid) { _ in }
        case "delete":
            devices.withLock { $0.removeAll { $0.udid == udid } }
            return .output("")
        default: return .failure(64, "unknown subcommand")
        }
    }

    private func create(name: String, deviceType: String, runtime: String) -> CommandResult {
        let udid = UUID().uuidString
        devices.withLock { $0.append(Device(udid: udid, name: name, runtime: runtime, deviceType: deviceType)) }
        return .output(udid + "\n")
    }

    private func update(_ udid: String, _ change: @Sendable (inout Device) -> Void) -> CommandResult {
        devices.withLock { devices in
            guard let index = devices.firstIndex(where: { $0.udid == udid }) else {
                return .failure(148, "Invalid device: \(udid)")
            }
            change(&devices[index])
            return .output("")
        }
    }

    /// `simctl list -j` の形（使う欄だけ）
    private func listJSON() -> String {
        func type(_ name: String, _ identifier: String) -> [String: Any] { ["name": name, "identifier": identifier] }
        let iPhone17 = type("iPhone 17 Pro", Self.iPhone17Pro)
        let iPhone18 = type("iPhone 18 Pro", Self.iPhone18Pro)
        let iPad = type("iPad Pro 13-inch (M5)", Self.iPadPro13)
        func runtime(_ identifier: String, _ version: String, _ types: [[String: Any]], platform: String = "iOS") -> [String: Any] {
            ["identifier": identifier, "platform": platform, "version": version, "isAvailable": true, "supportedDeviceTypes": types]
        }
        let runtimes: [[String: Any]] = [
            runtime(Self.iOS265, "26.5", [iPhone17, iPad]),
            runtime(Self.iOS270, "27.0", [iPhone17, iPhone18]),
            runtime(Self.iOS271, "27.1", [iPhone18]),
            runtime(Self.xrOS265, "26.5", [type("Apple Vision Pro", Self.visionPro)], platform: "xrOS")
        ]
        var grouped: [String: [[String: Any]]] = [:]
        for device in current {
            grouped[device.runtime, default: []].append([
                "udid": device.udid, "name": device.name, "state": device.state, "isAvailable": device.isAvailable,
                "deviceTypeIdentifier": device.deviceType, "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/\(device.udid)"
            ])
        }
        let object: [String: Any] = ["devicetypes": [iPhone17, iPhone18, iPad], "runtimes": runtimes, "devices": grouped, "pairs": [:]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
