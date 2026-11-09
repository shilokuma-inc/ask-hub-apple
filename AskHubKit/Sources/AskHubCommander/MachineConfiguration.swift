import AskHubKeychain
import AskHubProtocol
import Foundation

/// 司令塔とワーカーの役割。どちらも同じ部品（設定・Keychain・作業場所・ジョブの実行）で動き、置き場所と名前だけを分ける
public enum MachineRole: String, CaseIterable, Sendable {
    /// 常時オンの Mac の司令塔（ワーカーの仕事も行う）
    case commander
    /// 開始のときに人が選んだ Mac のワーカー
    case worker

    /// 実行ファイルの名前
    public var program: String { "askhub-\(rawValue)" }

    /// Keychain の項目のサービス名。役割ごとに分ける
    public var keychainService: String { "jp.shilokuma.AskHub.\(rawValue)" }

    /// LaunchAgent のラベル
    public var launchAgentLabel: String { "jp.shilokuma.askhub.\(rawValue)" }

    /// この役割で動かせる Mac の種類。司令塔は常時オンの Mac、ワーカーは常駐できる Mac とできない Mac
    public var kinds: [MacKind] {
        switch self {
        case .commander: [.alwaysOn]
        case .worker: [.resident, .manual]
        }
    }
}

/// 司令塔とワーカーの設定（`setup` で書き、`run` で読む）。秘密（トークン）は含めない（Keychain に置く）
public struct MachineConfiguration: Codable, Equatable, Sendable {
    /// 状態リポジトリ
    public var stateRepository: RepositoryFullName
    /// 状態リポジトリのブランチ。nil なら既定のブランチ
    public var stateBranch: String?
    /// この Mac の名前（`macs/<mac>.json`・ジョブの担当）
    public var mac: MacName
    /// この Mac の種類（生きている印に書く）。司令塔は常時オン、ワーカーは常駐できるか・できないか
    public var kind: MacKind
    /// 版を固定した `claude` の実行ファイル（絶対パス）
    public var claude: String
    /// 公開鍵を結びつけてよい GitHub のアカウント（公開鍵の記録を確かめるときに使う）
    public var keyAccounts: [String]
    /// この Mac で同時に動かす数
    public var capacity: MacFile.Capacity
    /// GitHub のトークンを置く、状態リポジトリのほかの持ち主（対象のリポジトリの organization・個人）。
    /// fine-grained token は 1 つの持ち主のリポジトリしか扱えないので、持ち主ごとに Keychain に置く（`tokenOwners`）
    public var githubOwners: [String]
    /// 進行を止めるものを APNs で知らせるための設定（司令塔だけ。`askhub-commander apns` で足す）。無ければ知らせない
    public var apns: APNsConfiguration?

    public init(
        stateRepository: RepositoryFullName,
        stateBranch: String? = nil,
        mac: MacName,
        kind: MacKind = .alwaysOn,
        claude: String,
        keyAccounts: [String],
        capacity: MacFile.Capacity = .init(claude: 2, build: 0),
        githubOwners: [String] = [],
        apns: APNsConfiguration? = nil
    ) {
        self.stateRepository = stateRepository
        self.stateBranch = stateBranch
        self.mac = mac
        self.kind = kind
        self.claude = claude
        self.keyAccounts = keyAccounts
        self.capacity = capacity
        self.githubOwners = githubOwners
        self.apns = apns
    }

    /// GitHub のトークンを置く持ち主（状態リポジトリの持ち主が先頭。小文字にそろえ、重ねない）
    public var tokenOwners: [String] {
        var owners: [String] = []
        for owner in [stateRepository.owner] + githubOwners {
            guard let normalized = GitHubTokens.normalizedOwner(owner), !owners.contains(normalized) else { continue }
            owners.append(normalized)
        }
        return owners
    }

    /// 設定の形の問題。空なら使える
    public var problems: [String] {
        var problems: [String] = []
        if !claude.hasPrefix("/") { problems.append("claude は絶対パスで書く") }
        if keyAccounts.isEmpty || keyAccounts.contains(where: \.isEmpty) { problems.append("keyAccounts に GitHub のアカウントを 1 つ以上書く") }
        if capacity.claude < 1 { problems.append("capacity.claude は 1 以上") }
        if capacity.build < 0 { problems.append("capacity.build は 0 以上") }
        if let owner = githubOwners.first(where: { GitHubTokens.normalizedOwner($0) == nil }) {
            problems.append("githubOwners の \(owner) は GitHub の持ち主の名前の形でない")
        }
        problems += apns?.problems ?? []
        return problems
    }

    /// 設定を読む。`role` で動かせない種類の Mac の設定（ワーカーの設定を司令塔で読むなど）は断る
    public static func load(from url: URL, role: MachineRole) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        var problems = configuration.problems
        if !role.kinds.contains(configuration.kind) { problems.append("\(role.program) では \(configuration.kind.rawValue) の Mac を動かせない") }
        guard problems.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: problems.joined(separator: "、")])
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

/// 司令塔とワーカーが使う置き場所。作業ファイルは TCC の保護の外に置く。
///
/// 対象のリポジトリの写しと DerivedData は、パスに空白の無い `~/Library/Developer/AskHub/<役割>` に置く。
/// パスの空白を扱えないビルドのプラグインやスクリプトがあるため（LicenseList のプラグインが、空白を `%20` にしたパスで
/// `SourcePackages` を探して見つけられず、ビルドが止まった）。設定と Claude のフォルダは `~/Library/Application Support/AskHub/<役割>` に置く
public struct MachinePaths: Sendable {
    public var role: MachineRole
    /// `~/Library/Application Support/AskHub/<役割>`（設定・Claude）
    public var root: URL
    /// `~/Library/Developer/AskHub/<役割>`（リポジトリの写し・epic の作業場所・DerivedData。パスに空白を入れない）
    public var workRoot: URL
    /// `~/Library/Logs/AskHub`
    public var logs: URL

    public init(role: MachineRole, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.role = role
        root = home.appendingPathComponent("Library/Application Support/AskHub/\(role.rawValue)", isDirectory: true)
        workRoot = home.appendingPathComponent("Library/Developer/AskHub/\(role.rawValue)", isDirectory: true)
        logs = home.appendingPathComponent("Library/Logs/AskHub", isDirectory: true)
    }

    public var configuration: URL { root.appendingPathComponent("config.json") }
    /// Claude の setup-token を入れた日（値は Keychain にだけ置き、ここには日付だけを書く。`ClaudeTokenRecord`）
    public var claudeTokenRecord: URL { root.appendingPathComponent("claude-token.json") }
    /// 対象のリポジトリの写しと、epic の作業場所
    public var work: URL { workRoot.appendingPathComponent("work", isDirectory: true) }
    /// Claude 専用の設定フォルダ（`CLAUDE_CONFIG_DIR`）。人の `~/.claude` を効かせない
    public var claudeConfig: URL { root.appendingPathComponent("claude/config", isDirectory: true) }
    public var claudeHome: URL { root.appendingPathComponent("claude/home", isDirectory: true) }
    public var claudeTemporary: URL { root.appendingPathComponent("claude/tmp", isDirectory: true) }
    /// epic ごとの DerivedData と結果のバンドル（`AskHubBuild` の `BuildDirectories`）
    public var builds: URL { workRoot.appendingPathComponent("builds", isDirectory: true) }
    /// ビルドとテストの TMPDIR
    public var buildTemporary: URL { workRoot.appendingPathComponent("builds-tmp", isDirectory: true) }
    public var log: URL { logs.appendingPathComponent("\(role.rawValue).log") }

    /// `run` の前に作っておくフォルダ
    public var directories: [URL] { [work, claudeConfig, claudeHome, claudeTemporary, builds, buildTemporary, logs] }
}
