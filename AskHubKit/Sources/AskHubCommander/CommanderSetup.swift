import AskHubProtocol
import Foundation

/// `askhub-commander setup` の引数（トークンは引数で受け取らず、端末で伏せて入れる）
public struct CommanderSetup: Equatable, Sendable {
    public struct Failure: Error, Equatable, Sendable {
        public var message: String
    }

    public var configuration: CommanderConfiguration
    /// 公開鍵の記録の最初の鍵（セットアップで固定する）
    public var firstKey: KeyID

    public static func parse(_ arguments: [String]) throws(Failure) -> Self {
        let known: Set = ["state-repo", "state-branch", "mac", "claude", "first-key", "key-account", "claude-capacity"]
        let values = try flags(arguments, known: known)
        func one(_ name: String) throws(Failure) -> String {
            try required(name, in: values)
        }
        guard let repo = RepositoryFullName(rawValue: try one("state-repo")) else { throw Failure(message: "--state-repo は owner/repo の形") }
        guard let mac = MacName(rawValue: try one("mac")) else { throw Failure(message: "--mac の形が違う") }
        guard let firstKey = KeyID(rawValue: try one("first-key")) else { throw Failure(message: "--first-key の形が違う") }
        var capacity = MacFile.Capacity(claude: 2, build: 0)
        if let text = values["claude-capacity"]?.last {
            guard let count = Int(text), count >= 1 else { throw Failure(message: "--claude-capacity は 1 以上の数") }
            capacity.claude = count
        }
        let configuration = CommanderConfiguration(
            stateRepository: repo,
            stateBranch: values["state-branch"]?.last,
            mac: mac,
            claude: try one("claude"),
            keyAccounts: values["key-account"] ?? [],
            capacity: capacity
        )
        if let problem = configuration.problems.first { throw Failure(message: problem) }
        return Self(configuration: configuration, firstKey: firstKey)
    }

    /// `--名前 値` の並びを読む。同じ名前は並べた順に持つ。`known` に無い名前は断る
    static func flags(_ arguments: [String], known: Set<String>) throws(Failure) -> [String: [String]] {
        var values: [String: [String]] = [:]
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--"), let value = rest.popFirst() else { throw Failure(message: "\(flag) の値が無い") }
            values[String(flag.dropFirst(2)), default: []].append(value)
        }
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) { throw Failure(message: "知らない引数 --\(unknown)") }
        return values
    }

    /// 1 つだけ要る値（並べたら最後のもの）
    static func required(_ name: String, in values: [String: [String]]) throws(Failure) -> String {
        guard let value = values[name]?.last, !value.isEmpty else { throw Failure(message: "--\(name) が要る") }
        return value
    }

    /// 貼られた Claude のトークンの問題。setup-token なら nil（API キーは従量課金になるので受け付けない）
    public static func claudeTokenProblem(_ token: String) -> String? {
        if token.hasPrefix("sk-ant-api03-") { return "API キー（従量課金）は使わない。`claude setup-token` で作ったトークンを貼る" }
        if !token.hasPrefix(MachineProbe.claudeTokenPrefix) { return "setup-token（sk-ant-oat01- で始まる）の形でない" }
        return nil
    }
}
