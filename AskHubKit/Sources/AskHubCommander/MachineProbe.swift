import AskHubKeychain
import AskHubProtocol
import Foundation

/// 生きている印に書く、この Mac の様子（空き容量・負荷・自己診断）
public struct MachineProbe: Sendable {
    public var secrets: any SecretStore
    /// 空き容量を測るフォルダ（作業ファイルを置くボリューム）
    public var volume: URL
    public var now: @Sendable () -> Date

    public init(secrets: any SecretStore, volume: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.secrets = secrets
        self.volume = volume
        self.now = now
    }

    public func status() -> CommanderLoop.MachineStatus {
        CommanderLoop.MachineStatus(diskFreeGB: diskFreeGB(), load: load(), selfCheck: selfCheck())
    }

    /// Keychain に必要なものがあり、形が合っているか。値そのものは書かない
    public func selfCheck() -> SelfCheck {
        let github: SelfCheck.State
        let claude: SelfCheck.State
        do {
            github = Self.state(of: try secrets.read(.githubToken)) { !$0.isEmpty }
            claude = Self.state(of: try secrets.read(.claudeToken)) { $0.hasPrefix(Self.claudeTokenPrefix) }
        } catch {
            return SelfCheck(checkedAt: Timestamp(now()), keychain: .invalid, githubToken: .missing, claudeToken: .missing)
        }
        return SelfCheck(checkedAt: Timestamp(now()), keychain: .ok, githubToken: github, claudeToken: claude)
    }

    /// Claude の setup-token の先頭（API キーは `sk-ant-api03-` で、従量課金になるので受け付けない）
    public static let claudeTokenPrefix = "sk-ant-oat01-"

    private static func state(of data: Data?, isValid: (String) -> Bool) -> SelfCheck.State {
        guard let data else { return .missing }
        guard let text = String(bytes: data, encoding: .utf8), isValid(text) else { return .invalid }
        return .ok
    }

    private func diskFreeGB() -> Int {
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
    }

    private func load() -> Double {
        var averages = [Double](repeating: 0, count: 1)
        return getloadavg(&averages, 1) == 1 ? averages[0] : 0
    }
}
