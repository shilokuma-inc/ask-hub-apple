import AskHubProtocol
import Foundation

/// 非常口のコマンド（`askhub`）の設定。秘密（トークン・署名の鍵）は含めない（Keychain に置く）
public struct ClientConfiguration: Codable, Equatable, Sendable {
    public var stateRepository: RepositoryFullName
    public var stateBranch: String?

    public init(stateRepository: RepositoryFullName, stateBranch: String? = nil) {
        self.stateRepository = stateRepository
        self.stateBranch = stateBranch
    }

    /// `~/Library/Application Support/AskHub/cli/config.json`
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AskHub/cli/config.json")
    }

    /// Keychain の項目のサービス名（司令塔とは分ける）
    public static let keychainService = "jp.shilokuma.AskHub.cli"

    public static func load(from url: URL = url()) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = url()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// `--名前 値` の形の引数（同じ名前は最後のものを使う）
public struct CommandArguments: Sendable {
    public var values: [String: String] = [:]
    public var positional: [String] = []

    public struct Failure: Error, Equatable, Sendable {
        public var message: String

        public init(message: String) {
            self.message = message
        }
    }

    public init(_ arguments: [String]) throws(Failure) {
        var rest = arguments[...]
        while let item = rest.popFirst() {
            guard item.hasPrefix("--") else {
                positional.append(item)
                continue
            }
            guard let value = rest.popFirst() else { throw Failure(message: "\(item) の値が無い") }
            values[String(item.dropFirst(2))] = value
        }
    }

    public func string(_ name: String) throws(Failure) -> String {
        guard let value = values[name], !value.isEmpty else { throw Failure(message: "--\(name) が要る") }
        return value
    }

    public func repository(_ name: String = "repo") throws(Failure) -> RepositoryFullName {
        guard let repo = RepositoryFullName(rawValue: try string(name)) else { throw Failure(message: "--\(name) は owner/repo の形") }
        return repo
    }

    public func epic() throws(Failure) -> ULID {
        guard let epic = ULID(rawValue: try string("epic")) else { throw Failure(message: "--epic の形が違う") }
        return epic
    }

    public func integer(_ name: String) throws(Failure) -> Int {
        guard let value = Int(try string(name)), value >= 1 else { throw Failure(message: "--\(name) は 1 以上の数") }
        return value
    }

    /// 知らない引数があれば断る
    public func only(_ names: Set<String>) throws(Failure) {
        if let unknown = values.keys.sorted().first(where: { !names.contains($0) }) { throw Failure(message: "知らない引数 --\(unknown)") }
    }
}
