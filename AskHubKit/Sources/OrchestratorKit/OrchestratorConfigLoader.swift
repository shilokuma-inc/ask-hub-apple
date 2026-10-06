import AskHubKit
import Foundation

/// 設定ファイル（JSON）を読み込んで検証する。
///
/// ```json
/// {
///   "trustedAuthors": ["mrs1669"],
///   "org": "shilokuma-inc",
///   "repositories": [
///     { "repository": "shilokuma-inc/ask-hub-apple", "path": "~/Desktop/ios/ask-hub-apple" }
///   ],
///   "pollIntervalSeconds": 60,
///   "loopCommand": ["/path/to/start-loop.sh", "{repository}", "{controlPath}"]
/// }
/// ```
/// `trustedAuthors`・`pollIntervalSeconds`・`ideaCommand`・`iterationTimeoutMinutes` は省略できる
/// （既定値は `TrustedAuthors.default`・60 秒・`IdeaCommandTemplate.defaultArguments`・90 分）。
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
        let org = file.org.trimmingCharacters(in: .whitespaces)
        guard !org.isEmpty else {
            throw .emptyOrg
        }
        guard !file.repositories.isEmpty else {
            throw .noRepositories
        }

        var repositories: [RepositoryConfig] = []
        for entry in file.repositories {
            let repository = try repositoryConfig(from: entry, org: org)
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

        return OrchestratorConfig(
            trustedAuthorLogins: trustedAuthors,
            org: org,
            repositories: repositories,
            pollInterval: .seconds(seconds),
            loopCommand: try LoopCommandTemplate(arguments: file.loopCommand),
            ideaCommand: try IdeaCommandTemplate(arguments: file.ideaCommand ?? IdeaCommandTemplate.defaultArguments),
            iterationTimeout: .seconds(timeoutMinutes * 60)
        )
    }

    private func repositoryConfig(
        from entry: ConfigFile.Repository,
        org: String
    ) throws(OrchestratorConfigError) -> RepositoryConfig {
        let parts = entry.repository.split(separator: "/", omittingEmptySubsequences: false)
        let isValidPart = { (part: Substring) in
            !part.isEmpty && !part.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
        }
        guard parts.count == 2, parts.allSatisfy(isValidPart) else {
            throw .invalidRepositoryName(entry.repository)
        }
        // 受信箱は org 全体を検索するため（Discussion #1 の Q6）、org の外のリポジトリは扱えない
        guard parts[0].caseInsensitiveCompare(org) == .orderedSame else {
            throw .repositoryOutsideOrg(repository: entry.repository, org: org)
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
    private func expandingTilde(in path: String) -> String {
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
    let org: String
    let repositories: [Repository]
    let pollIntervalSeconds: Int?
    let loopCommand: [String]
    let ideaCommand: [String]?
    let iterationTimeoutMinutes: Int?
}
