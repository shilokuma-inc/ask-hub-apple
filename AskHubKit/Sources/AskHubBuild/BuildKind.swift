import AskHubProtocol
import Foundation

/// ビルドとテストの種類（`docs/renewal/flows.md` の「Claude にビルドとテストを頼ませる」の `buildKind`）。
/// 頼む側はこれだけを選び、コマンドの中身は `BuildSettings`（`AskHubProtocol`。`repo.json` の `build.xcode`）から決まる
public enum BuildKind: String, Codable, Sendable, CaseIterable {
    /// ビルドだけ
    case build
    /// 軽いテスト（`BuildSettings.testLight`）
    case testLight
    /// 全部のテスト（`BuildSettings.testFull`）
    case testFull

    public var isTest: Bool { self != .build }
}

extension BuildSettings {
    /// `-project` か `-workspace` か
    public var projectOption: String {
        project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    }

    /// 種類ごとに流すテスト。ビルドだけなら nil
    public func tests(for kind: BuildKind) -> TestSelection? {
        switch kind {
        case .build: nil
        case .testLight: testLight
        case .testFull: testFull
        }
    }
}

extension SimulatorPlatform {
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
