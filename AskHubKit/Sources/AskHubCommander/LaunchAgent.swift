import Foundation

/// 司令塔を、ログイン中のセッションの LaunchAgent として常駐させる定義（ssh のセッションからは Keychain を読めないため）
public enum LaunchAgent {
    public static let label = "jp.shilokuma.askhub.commander"

    /// `~/Library/LaunchAgents/<label>.plist` の中身
    public static func plist(executable: URL, log: URL) throws -> Data {
        let definition: [String: Any] = [
            "Label": label,
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

    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
}
