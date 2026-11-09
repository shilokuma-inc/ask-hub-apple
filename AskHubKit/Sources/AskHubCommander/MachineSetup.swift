import AskHubProtocol
import Foundation

/// `askhub-commander setup`・`askhub-worker setup` の引数（トークンは引数で受け取らず、端末で伏せて入れる）
public struct MachineSetup: Equatable, Sendable {
    public struct Failure: Error, Equatable, Sendable {
        public var message: String
    }

    public var configuration: MachineConfiguration
    /// 公開鍵の記録の最初の鍵（セットアップで固定する）
    public var firstKey: KeyID

    /// 役割ごとの引数を読む。ワーカーは Mac の種類（`--kind resident|manual`）も受け取る。
    /// ビルドの同時の上限は両方で受け取る（常時オンの Mac が epic の Mac に選ばれたら、司令塔が実装のジョブも引き受けるため。司令塔の既定は 0）
    public static func parse(_ arguments: [String], role: MachineRole) throws(Failure) -> Self {
        var known: Set = [
            "state-repo", "state-branch", "mac", "claude", "first-key", "key-account", "claude-capacity", "build-capacity", "github-owner"
        ]
        if role == .worker { known.insert("kind") }
        let values = try flags(arguments, known: known)
        func one(_ name: String) throws(Failure) -> String {
            try required(name, in: values)
        }
        guard let repo = RepositoryFullName(rawValue: try one("state-repo")) else { throw Failure(message: "--state-repo は owner/repo の形") }
        guard let mac = MacName(rawValue: try one("mac")) else { throw Failure(message: "--mac の形が違う") }
        guard let firstKey = KeyID(rawValue: try one("first-key")) else { throw Failure(message: "--first-key の形が違う") }
        let kind: MacKind
        switch role {
        case .commander:
            kind = .alwaysOn
        case .worker:
            guard let value = MacKind(rawValue: try one("kind")), role.kinds.contains(value) else {
                throw Failure(message: "--kind は resident（常駐できる）か manual（常駐できない）")
            }
            kind = value
        }
        let capacity = MacFile.Capacity(
            claude: try count("claude-capacity", in: values, default: 2, minimum: 1),
            build: try count("build-capacity", in: values, default: role == .worker ? 1 : 0, minimum: 0)
        )
        let configuration = MachineConfiguration(
            stateRepository: repo,
            stateBranch: values["state-branch"]?.last,
            mac: mac,
            kind: kind,
            claude: try one("claude"),
            keyAccounts: values["key-account"] ?? [],
            capacity: capacity,
            githubOwners: values["github-owner"] ?? []
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

    /// 数の値。無ければ `fallback`
    private static func count(_ name: String, in values: [String: [String]], default fallback: Int, minimum: Int) throws(Failure) -> Int {
        guard let text = values[name]?.last else { return fallback }
        guard let count = Int(text), count >= minimum else { throw Failure(message: "--\(name) は \(minimum) 以上の数") }
        return count
    }

    /// 貼られた Claude のトークンの問題。setup-token なら nil（API キーは従量課金になるので受け付けない）
    public static func claudeTokenProblem(_ token: String) -> String? {
        if token.hasPrefix("sk-ant-api03-") { return "API キー（従量課金）は使わない。`claude setup-token` で作ったトークンを貼る" }
        if !token.hasPrefix(MachineProbe.claudeTokenPrefix) { return "setup-token（sk-ant-oat01- で始まる）の形でない" }
        return nil
    }
}

/// `askhub-commander apns` の引数。APNs の鍵（.p8）を Keychain に置き、鍵の id と Team ID を設定に足す
public struct APNsSetup: Equatable, Sendable {
    public var configuration: APNsConfiguration
    /// Apple Developer から落とした .p8 のパス。中身は Keychain にだけ置き、設定には書かない
    public var keyFile: String

    public static func parse(_ arguments: [String]) throws(MachineSetup.Failure) -> Self {
        let values = try MachineSetup.flags(arguments, known: ["key-id", "team-id", "key-file", "topic"])
        let configuration = APNsConfiguration(
            keyId: try MachineSetup.required("key-id", in: values),
            teamId: try MachineSetup.required("team-id", in: values),
            topic: values["topic"]?.last ?? APNsConfiguration.defaultTopic
        )
        if let problem = configuration.problems.first { throw .init(message: problem) }
        return Self(configuration: configuration, keyFile: try MachineSetup.required("key-file", in: values))
    }

    /// 前の設定に書いた APNs の設定。setup を流し直しても残す（.p8 は Mac に残さないので、登録し直せないことがある）。
    /// 設定のほかの欄の形が変わっていても、この欄だけを読む
    public static func preserved(at url: URL) -> APNsConfiguration? {
        struct Stored: Decodable {
            var apns: APNsConfiguration?
        }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.apns
    }
}
