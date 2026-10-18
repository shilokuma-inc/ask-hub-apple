import AskHubKit
import Foundation

/// 設定ファイル（JSON）を読み込んで検証する。
///
/// ```json
/// {
///   "trustedAuthors": ["mrs1669"],
///   "repositories": [
///     { "repository": "shilokuma-inc/ask-hub-apple", "path": "~/Desktop/ios/ask-hub-apple" },
///     { "repository": "BeaconFun4/demomoni-remake-ios", "path": "~/Desktop/ios/demomoni-remake-ios" }
///   ],
///   "pollIntervalSeconds": 60,
///   "loopCommand": ["/path/to/start-loop.sh", "{repository}", "{controlPath}"]
/// }
/// ```
/// `trustedAuthors`・`pollIntervalSeconds`・`ideaCommand`・`iterationTimeoutMinutes` は省略できる
/// （既定値は `TrustedAuthors.default`・60 秒・`IdeaCommandTemplate.defaultArguments`・90 分）。
/// `createRepositoryCommand`・`removeRepositoryCommand`・`newRepositoryDirectory` も省略でき、既定は
/// `~/.local/bin/askhub-create-repo`・`~/.local/bin/askhub-remove-repo`・最初の担当リポジトリと同じディレクトリ。
/// `trustRepositoryWriters`（担当リポジトリに書き込み権限を持つアカウントも信用するか）も省略でき、既定は `true`。
/// 検索する organization は担当リポジトリの owner から決める。以前の `org` が残っていても無視する。
/// `buildHosts`（xcb のビルドの Mac の情報の書き出し）も省略でき、省略するとその機能を止める:
///
/// ```json
/// "buildHosts": { "xcb": "~/.config/askhub/xcodebuild", "issueRepository": "shilokuma-inc/ask-hub-apple" }
/// ```
/// `eventsDirectory`（xcb の `events.jsonl` の場所）の既定は `BuildHostsConfig.defaultEventsDirectory`。
/// `model`（起動する claude のモデル。既定は `LoopModel.standard`）と `effort`（`low` / `medium` / `high` / `xhigh` / `max`。既定は claude の既定）も省略できる
public struct OrchestratorConfigLoader: Sendable {
    /// `~` の展開に使うホームディレクトリ。テストで差し替える
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    /// 設定ファイルの既定の場所
    public var defaultPath: String {
        expandingTilde(in: "~/.config/askhub/orchestrator.json")
    }

    public func load(from path: String) throws(OrchestratorConfigError) -> OrchestratorConfig {
        let expandedPath = expandingTilde(in: path)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw .fileNotFound(path: expandedPath)
        } catch {
            throw .unreadable(path: expandedPath, reason: error.localizedDescription)
        }
        return try decode(data)
    }

    public func decode(_ data: Data) throws(OrchestratorConfigError) -> OrchestratorConfig {
        let file: ConfigFile
        do {
            file = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch let error as DecodingError {
            throw .invalidJSON(reason: Self.describe(error))
        } catch {
            throw .invalidJSON(reason: error.localizedDescription)
        }
        return try validate(file)
    }

    private func validate(_ file: ConfigFile) throws(OrchestratorConfigError) -> OrchestratorConfig {
        let trustedAuthors = (file.trustedAuthors ?? TrustedAuthors.defaultLogins)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trustedAuthors.isEmpty else {
            throw .emptyTrustedAuthors
        }
        guard !file.repositories.isEmpty else {
            throw .noRepositories
        }

        var repositories: [RepositoryConfig] = []
        for entry in file.repositories {
            let repository = try repositoryConfig(from: entry)
            if repositories.contains(where: { $0.fullName.caseInsensitiveCompare(repository.fullName) == .orderedSame }) {
                throw .duplicateRepository(repository.fullName)
            }
            repositories.append(repository)
        }

        let seconds = file.pollIntervalSeconds ?? Int(OrchestratorConfig.defaultPollInterval.components.seconds)
        let minimum = Int(OrchestratorConfig.minimumPollInterval.components.seconds)
        guard seconds >= minimum else {
            throw .pollIntervalTooShort(seconds: seconds, minimum: minimum)
        }

        let timeoutMinutes = file.iterationTimeoutMinutes ?? Int(OrchestratorConfig.defaultIterationTimeout.components.seconds / 60)
        let minimumMinutes = Int(OrchestratorConfig.minimumIterationTimeout.components.seconds / 60)
        let maximumMinutes = Int(OrchestratorConfig.maximumIterationTimeout.components.seconds / 60)
        // 秒への変換であふれないよう、変換の前に範囲を確かめる
        guard (minimumMinutes...maximumMinutes).contains(timeoutMinutes) else {
            throw .iterationTimeoutOutOfRange(minutes: timeoutMinutes, minimum: minimumMinutes, maximum: maximumMinutes)
        }

        let repositoryCommands = try repositoryCommands(from: file, repositories: repositories)
        let (model, effort) = try claudeOptions(from: file)

        return OrchestratorConfig(
            trustedAuthorLogins: trustedAuthors,
            repositories: repositories,
            pollInterval: .seconds(seconds),
            loopCommand: try LoopCommandTemplate(arguments: file.loopCommand),
            ideaCommand: try IdeaCommandTemplate(arguments: file.ideaCommand ?? IdeaCommandTemplate.defaultArguments),
            iterationTimeout: .seconds(timeoutMinutes * 60),
            conflictCommand: try file.conflictCommand.map { arguments throws(OrchestratorConfigError) in
                try ConflictCommandTemplate(arguments: arguments)
            },
            ciFixCommand: try file.ciFixCommand.map { arguments throws(OrchestratorConfigError) in
                try CIFixCommandTemplate(arguments: arguments)
            },
            repositoryCommands: repositoryCommands,
            trustsRepositoryWriters: file.trustRepositoryWriters ?? true,
            buildHosts: try file.buildHosts.map { entry throws(OrchestratorConfigError) in try buildHostsConfig(from: entry) },
            claudeModel: model,
            claudeEffort: effort
        )
    }

    /// 起動する claude のモデル（省略時は `LoopModel.standard`）とエフォート（省略時は claude の既定）
    private func claudeOptions(from file: ConfigFile) throws(OrchestratorConfigError) -> (model: String, effort: LoopEffort?) {
        let model = file.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? LoopModel.standard.rawValue
        guard Self.isModelName(model) else {
            throw .invalidModel(model)
        }
        guard let value = file.effort else {
            return (model, nil)
        }
        guard let effort = LoopEffort(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .invalidEffort(value)
        }
        return (model, effort)
    }

    /// xcb の場所は絶対パス（`~` 可）。`issueRepository` は `owner/repo` の形だけを確かめる（担当リポジトリかは使うときに照らす）
    private func buildHostsConfig(from entry: ConfigFile.BuildHosts) throws(OrchestratorConfigError) -> BuildHostsConfig {
        let absolutePath = { (key: String, path: String) throws(OrchestratorConfigError) -> String in
            let expanded = expandingTilde(in: path.trimmingCharacters(in: .whitespacesAndNewlines))
            guard expanded.hasPrefix("/") else {
                throw .relativeBuildHostsPath(key: key, path: path)
            }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let issueRepository = entry.issueRepository?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let issueRepository {
            guard Self.isRepositoryName(issueRepository.split(separator: "/", omittingEmptySubsequences: false)) else {
                throw .invalidBuildHostsRepository(issueRepository)
            }
        }
        return BuildHostsConfig(
            xcbPath: try absolutePath("buildHosts.xcb", entry.xcb),
            eventsDirectory: try absolutePath(
                "buildHosts.eventsDirectory", entry.eventsDirectory ?? BuildHostsConfig.defaultEventsDirectory
            ),
            issueRepository: issueRepository
        )
    }

    /// 担当リポジトリの作成・削除に使うコマンドと場所。省略されたものは既定にする
    private func repositoryCommands(
        from file: ConfigFile,
        repositories: [RepositoryConfig]
    ) throws(OrchestratorConfigError) -> RepositoryCommands {
        let directory = try file.newRepositoryDirectory.map { path throws(OrchestratorConfigError) in
            let expanded = expandingTilde(in: path)
            guard expanded.hasPrefix("/") else {
                throw .relativeNewRepositoryDirectory(path)
            }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        } ?? RepositoryCommands.defaultCheckoutDirectory(for: repositories, homeDirectory: homeDirectory)
        let standard = RepositoryCommands.standard(homeDirectory: homeDirectory, newCheckoutDirectory: directory)
        return RepositoryCommands(
            create: try commandArguments(file.createRepositoryCommand, key: "createRepositoryCommand") ?? standard.create,
            remove: try commandArguments(file.removeRepositoryCommand, key: "removeRepositoryCommand") ?? standard.remove,
            newCheckoutDirectory: directory
        )
    }

    /// 引数の配列のコマンド。省略されていれば `nil`、空なら設定エラー。先頭の `~` は展開する
    private func commandArguments(_ arguments: [String]?, key: String) throws(OrchestratorConfigError) -> [String]? {
        guard let arguments else {
            return nil
        }
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyRepositoryCommand(key: key)
        }
        return [expandingTilde(in: executable)] + arguments.dropFirst()
    }

    private func repositoryConfig(
        from entry: ConfigFile.Repository
    ) throws(OrchestratorConfigError) -> RepositoryConfig {
        let parts = entry.repository.split(separator: "/", omittingEmptySubsequences: false)
        guard Self.isRepositoryName(parts) else {
            throw .invalidRepositoryName(entry.repository)
        }
        let path = expandingTilde(in: entry.path)
        guard path.hasPrefix("/") else {
            throw .relativeCheckoutPath(repository: entry.repository, path: entry.path)
        }
        return RepositoryConfig(
            owner: String(parts[0]),
            name: String(parts[1]),
            checkoutPath: URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    /// 先頭の `~` だけを展開する（`~user` の形式は扱わない）
    /// `owner/repo` を `/` で分けたもの。どちらも空でなく、空白・改行・制御文字を含まない
    /// claude の `--model` に渡せる形（モデル ID か `opus` などの別名）。英数字で始まり、英数字・`.`・`_`・`-` だけ
    static func isModelName(_ name: String) -> Bool {
        let isAlphanumeric = { (scalar: Unicode.Scalar) in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard (1...100).contains(name.count), let first = name.unicodeScalars.first, isAlphanumeric(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { isAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }

    private static func isRepositoryName(_ parts: [Substring]) -> Bool {
        parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && !part.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
        }
    }

    func expandingTilde(in path: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + path.dropFirst()
        }
        return path
    }

    private static func describe(_ error: DecodingError) -> String {
        func keyPath(_ codingPath: [any CodingKey]) -> String {
            codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case let .keyNotFound(key, context):
            return "\(keyPath(context.codingPath + [key])) がありません"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(keyPath(context.codingPath)) の型が違います"
        case let .dataCorrupted(context):
            return context.codingPath.isEmpty ? "JSON として読めません" : "\(keyPath(context.codingPath)) の値が不正です"
        @unknown default:
            return error.localizedDescription
        }
    }
}

/// 設定ファイルの JSON の形。検証前の値
private struct ConfigFile: Decodable {
    struct Repository: Decodable {
        let repository: String
        let path: String
    }

    let trustedAuthors: [String]?
    let repositories: [Repository]
    let pollIntervalSeconds: Int?
    let loopCommand: [String]
    let ideaCommand: [String]?
    let iterationTimeoutMinutes: Int?
    let conflictCommand: [String]?
    let ciFixCommand: [String]?
    let createRepositoryCommand: [String]?
    let removeRepositoryCommand: [String]?
    let newRepositoryDirectory: String?
    let trustRepositoryWriters: Bool?
    let buildHosts: BuildHosts?
    let model: String?
    let effort: String?

    struct BuildHosts: Decodable {
        let xcb: String
        let eventsDirectory: String?
        let issueRepository: String?
    }
}
