import AskHubProtocol
import Foundation

/// 司令塔の設定（`setup` で書き、`run` で読む）。秘密（トークン）は含めない（Keychain に置く）
public struct CommanderConfiguration: Codable, Equatable, Sendable {
    /// 状態リポジトリ
    public var stateRepository: RepositoryFullName
    /// 状態リポジトリのブランチ。nil なら既定のブランチ
    public var stateBranch: String?
    /// この Mac の名前（`macs/<mac>.json`・ジョブの担当）
    public var mac: MacName
    /// 版を固定した `claude` の実行ファイル（絶対パス）
    public var claude: String
    /// 公開鍵を結びつけてよい GitHub のアカウント（公開鍵の記録を確かめるときに使う）
    public var keyAccounts: [String]
    /// この Mac で同時に動かす数
    public var capacity: MacFile.Capacity
    /// 進行を止めるものを APNs で知らせるための設定（`askhub-commander apns` で足す）。無ければ知らせない
    public var apns: APNsConfiguration?

    public init(
        stateRepository: RepositoryFullName,
        stateBranch: String? = nil,
        mac: MacName,
        claude: String,
        keyAccounts: [String],
        capacity: MacFile.Capacity = .init(claude: 2, build: 0),
        apns: APNsConfiguration? = nil
    ) {
        self.stateRepository = stateRepository
        self.stateBranch = stateBranch
        self.mac = mac
        self.claude = claude
        self.keyAccounts = keyAccounts
        self.capacity = capacity
        self.apns = apns
    }

    /// 設定の形の問題。空なら使える
    public var problems: [String] {
        var problems: [String] = []
        if !claude.hasPrefix("/") { problems.append("claude は絶対パスで書く") }
        if keyAccounts.isEmpty || keyAccounts.contains(where: \.isEmpty) { problems.append("keyAccounts に GitHub のアカウントを 1 つ以上書く") }
        if capacity.claude < 1 { problems.append("capacity.claude は 1 以上") }
        if capacity.build < 0 { problems.append("capacity.build は 0 以上") }
        problems += apns?.problems ?? []
        return problems
    }

    public static func load(from url: URL) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard configuration.problems.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: configuration.problems.joined(separator: "、")])
        }
        return configuration
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 司令塔が使う置き場所。作業ファイルは TCC の保護の外（`~/Library/Application Support/` の下）に置く
public struct CommanderPaths: Sendable {
    /// `~/Library/Application Support/AskHub/commander`
    public var root: URL
    /// `~/Library/Logs/AskHub`
    public var logs: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = home.appendingPathComponent("Library/Application Support/AskHub/commander", isDirectory: true)
        logs = home.appendingPathComponent("Library/Logs/AskHub", isDirectory: true)
    }

    public var configuration: URL { root.appendingPathComponent("config.json") }
    /// 対象のリポジトリの写し
    public var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    /// Claude 専用の設定フォルダ（`CLAUDE_CONFIG_DIR`）。人の `~/.claude` を効かせない
    public var claudeConfig: URL { root.appendingPathComponent("claude/config", isDirectory: true) }
    public var claudeHome: URL { root.appendingPathComponent("claude/home", isDirectory: true) }
    public var claudeTemporary: URL { root.appendingPathComponent("claude/tmp", isDirectory: true) }
    public var log: URL { logs.appendingPathComponent("commander.log") }

    /// Keychain の項目のサービス名
    public static let keychainService = "jp.shilokuma.AskHub.commander"
}
