import Foundation

/// 司令塔とワーカーを、ログイン中のセッションの LaunchAgent として常駐させる定義（ssh のセッションからは Keychain を読めないため）。
/// 常駐できない Mac（社用の MacBook など）のワーカーは使わず、ターミナルで `run` を流し続ける
public enum LaunchAgent {
    /// `~/Library/LaunchAgents/<label>.plist` の中身
    public static func plist(role: MachineRole, executable: URL, log: URL) throws -> Data {
        let definition: [String: Any] = [
            "Label": role.launchAgentLabel,
            "ProgramArguments": [executable.path, "run"],
            "RunAtLoad": true,
            // 落ちたら起こし直す。続けて落ちるときは launchd が間隔を空ける
            "KeepAlive": true,
            "ThrottleInterval": 60,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "ProcessType": "Standard"
        ]
        return try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
    }

    public static func path(role: MachineRole, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(role.launchAgentLabel).plist")
    }
}
