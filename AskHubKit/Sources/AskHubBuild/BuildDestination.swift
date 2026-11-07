import Foundation

/// ビルドとテストの行き先。JSON では `{"platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "26.5"}` か
/// `{"platform": "macOS"}` の形
public enum BuildDestination: Codable, Hashable, Sendable {
    /// ワーカーの枠の Simulator（`SimulatorPool`）で流す
    case simulator(SimulatorDestination)
    /// ワーカーの Mac そのもので流す
    case macOS

    private enum CodingKeys: String, CodingKey {
        case platform, deviceType, osVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let platform = try container.decode(String.self, forKey: .platform)
        if platform == "macOS" {
            self = .macOS
            return
        }
        guard let simulator = SimulatorPlatform(rawValue: platform) else {
            throw DecodingError.dataCorruptedError(forKey: .platform, in: container, debugDescription: "知らないプラットフォーム: \(platform)")
        }
        self = .simulator(SimulatorDestination(
            platform: simulator,
            deviceType: try container.decode(String.self, forKey: .deviceType),
            osVersion: try container.decodeIfPresent(String.self, forKey: .osVersion)
        ))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macOS:
            try container.encode("macOS", forKey: .platform)
        case .simulator(let destination):
            try container.encode(destination.platform.rawValue, forKey: .platform)
            try container.encode(destination.deviceType, forKey: .deviceType)
            try container.encodeIfPresent(destination.osVersion, forKey: .osVersion)
        }
    }

    func validate() throws(BuildSettingsError) {
        guard case .simulator(let destination) = self else { return }
        try BuildSettings.checkArgument(destination.deviceType, field: "destinations.deviceType")
        if let version = destination.osVersion, version.wholeMatch(of: #/[0-9]+(\.[0-9]+){0,2}/#) == nil {
            throw BuildSettingsError(field: "destinations.osVersion", reason: "`26.5` の形ではない")
        }
    }
}

/// Simulator の機種と OS
public struct SimulatorDestination: Codable, Hashable, Sendable {
    public var platform: SimulatorPlatform
    /// 機種の名前（`iPhone 17 Pro`）か識別子（`com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`）
    public var deviceType: String
    /// OS の版（`26.5`）。nil なら、使う Xcode の SDK と同じか古いランタイムのうち最新
    /// （新しいランタイムを古い Xcode で使うと、テストランナーが起動しないことがある）
    public var osVersion: String?

    public init(platform: SimulatorPlatform, deviceType: String, osVersion: String? = nil) {
        self.platform = platform
        self.deviceType = deviceType
        self.osVersion = osVersion
    }
}

/// Simulator のプラットフォーム
public enum SimulatorPlatform: String, Codable, Hashable, Sendable, CaseIterable {
    case iOS
    case visionOS

    /// SDK の名前（`xcrun --sdk <名前> --show-sdk-version`）
    var sdk: String {
        switch self {
        case .iOS: "iphonesimulator"
        case .visionOS: "xrsimulator"
        }
    }

    /// `simctl list -j` のランタイムの `platform`（visionOS だけ `xrOS`）
    var runtimePlatform: String {
        switch self {
        case .iOS: "iOS"
        case .visionOS: "xrOS"
        }
    }
}
