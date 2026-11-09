import AskHubProtocol
import Foundation

/// `xcrun simctl list -j` の結果のうち、使う欄
struct SimulatorCatalog: Decodable, Equatable {
    struct DeviceType: Decodable, Equatable {
        var name: String
        var identifier: String
    }

    struct Runtime: Decodable, Equatable {
        var identifier: String
        var platform: String?
        var version: String
        var isAvailable: Bool?
        var supportedDeviceTypes: [DeviceType]?
    }

    struct Device: Decodable, Equatable {
        var udid: String
        var name: String
        var state: String?
        var isAvailable: Bool?
        var deviceTypeIdentifier: String?
    }

    var runtimes: [Runtime]
    /// ランタイムの識別子ごとの Simulator
    var devices: [String: [Device]]

    /// すべての Simulator と、そのランタイムの識別子
    var allDevices: [Simulator] {
        devices.keys.sorted().flatMap { runtime in
            (devices[runtime] ?? []).map { device in
                Simulator(
                    udid: device.udid,
                    name: device.name,
                    runtime: runtime,
                    state: device.state ?? "",
                    isAvailable: device.isAvailable == true
                )
            }
        }
    }

    /// 行き先に合うランタイムと機種。`sdkVersion` は、OS の版の指定が無いときに選ぶランタイムの上限
    func resolve(_ destination: SimulatorDestination, sdkVersion: String?) throws(SimulatorError) -> (Runtime, DeviceType) {
        let candidates = runtimes.filter { runtime in
            runtime.isAvailable == true && runtime.platform == destination.platform.runtimePlatform
        }
        let matching: [Runtime]
        if let wanted = destination.osVersion {
            matching = candidates.filter { $0.version == wanted || $0.version.hasPrefix(wanted + ".") }
        } else if let sdkVersion {
            matching = candidates.filter { Self.compare($0.version, sdkVersion) != .orderedDescending }
        } else {
            matching = candidates
        }
        guard let newest = matching.max(by: { Self.compare($0.version, $1.version) == .orderedAscending }) else {
            let wanted = destination.osVersion ?? "SDK \(sdkVersion ?? "?") 以下"
            throw SimulatorError("\(destination.platform.rawValue) \(wanted) のランタイムが入っていない")
        }
        // 機種に対応するランタイムのうち最新を選ぶ。特定の機種だけのランタイム（iOS 27.1（24A94425）は iPhone Duo だけ）が
        // いちばん新しいと、ほかの機種を作れないため
        let supported = matching.compactMap { runtime in deviceType(destination.deviceType, in: runtime).map { (runtime, $0) } }
        guard let chosen = supported.max(by: { Self.compare($0.0.version, $1.0.version) == .orderedAscending }) else {
            throw SimulatorError("\(destination.platform.rawValue) \(newest.version) のランタイムに機種「\(destination.deviceType)」が無い")
        }
        return chosen
    }

    private func deviceType(_ wanted: String, in runtime: Runtime) -> DeviceType? {
        (runtime.supportedDeviceTypes ?? []).first { $0.name == wanted || $0.identifier == wanted }
    }

    /// 版（`26.5`・`26.5.1`）を数として比べる。足りない桁は 0 とみなす
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Simulator 1 台
public struct Simulator: Equatable, Hashable, Sendable {
    public var udid: String
    public var name: String
    /// ランタイムの識別子（`com.apple.CoreSimulator.SimRuntime.iOS-26-5`）
    public var runtime: String
    /// `Booted`・`Shutdown` など
    public var state: String
    /// ランタイムが消えたものは false
    public var isAvailable: Bool

    public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool = true) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
    }
}

/// Simulator を用意できない・操作できない（起動できない・つながらない・ランタイムが無いなど）
public struct SimulatorError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// `simctl` の出力の抜粋（伏せてある）
    public var log: String?

    public init(_ message: String, log: String? = nil) {
        self.message = message
        self.log = log
    }

    public var description: String { message }
}
