import Foundation

/// 対象に加える人の意図（`addRepository`）。封筒の `repo` が加えるリポジトリ。`target`・`targetVersion` は持たない
public struct AddRepositoryIntent: Equatable, Sendable {
    public static let kind = "addRepository"

    public var repo: RepositoryFullName
    public var platform: RepositoryPlatform
    public var intent: IntentReference

    public init(repo: RepositoryFullName, platform: RepositoryPlatform, intent: IntentReference) {
        self.repo = repo
        self.platform = platform
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が addRepository でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "対象に加える意図に target か targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["platform"])
        guard let platform = RepositoryPlatform(rawValue: try reader.text("platform", required: true, limit: 32)) else {
            throw .init(detail: "platform が知らない値")
        }
        self.init(repo: repo, platform: platform, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] {
        ["platform": .string(platform.rawValue)]
    }
}

/// ビルドの設定を入れる人の意図（`configureRepository`）。封筒の `repo` が対象のリポジトリ（対象に加えた後に送る）。
/// `target`・`targetVersion` は持たず、送るたびに `repo.json` の `build` をまるごと置き換える
public struct ConfigureRepositoryIntent: Equatable, Sendable {
    public static let kind = "configureRepository"

    public var repo: RepositoryFullName
    public var build: RepositoryFile.Build
    public var intent: IntentReference

    public init(repo: RepositoryFullName, build: RepositoryFile.Build, intent: IntentReference) {
        self.repo = repo
        self.build = build
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が configureRepository でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "ビルドの設定に target か targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["build"])
        guard let value = reader.payload["build"] else { throw .init(detail: "build が無い") }
        self.init(repo: repo, build: try Self.build(from: value), intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    /// `build` の値を読む。知らない欄（綴りの誤りなど）があれば、一部だけを設定として扱わないよう読まない
    public static func build(from value: JSONValue) throws(MalformedIntent) -> RepositoryFile.Build {
        let build: RepositoryFile.Build
        do {
            build = try JSONDecoder().decode(RepositoryFile.Build.self, from: CanonicalJSON.data(for: value))
        } catch {
            throw .init(detail: "build の形が違う（\(error)）")
        }
        guard build.problems.isEmpty else { throw .init(detail: build.problems.joined(separator: "、")) }
        // 読んだ値を書き直したものに、送られた値がすべて含まれる（読み飛ばした欄が無い）
        guard value.isContained(in: Self.value(of: build)) else { throw .init(detail: "build に知らない欄がある") }
        return build
    }

    public var payload: [String: JSONValue] {
        Self.payload(for: build)
    }

    public static func payload(for build: RepositoryFile.Build) -> [String: JSONValue] {
        ["build": value(of: build)]
    }

    private static func value(of build: RepositoryFile.Build) -> JSONValue {
        (try? JSONEncoder().encode(build)).flatMap { try? JSONValue(parsing: $0) } ?? .null
    }
}

extension JSONValue {
    /// `self` の欄と値が、すべて `other` にあるか（`other` だけにある欄は問わない。並びは同じ長さで、要素ごとに比べる）
    func isContained(in other: Self) -> Bool {
        switch (self, other) {
        case let (.object(fields), .object(others)):
            fields.allSatisfy { key, value in others[key].map(value.isContained) ?? false }
        case let (.array(items), .array(others)):
            items.count == others.count && zip(items, others).allSatisfy { $0.isContained(in: $1) }
        default:
            self == other
        }
    }
}
