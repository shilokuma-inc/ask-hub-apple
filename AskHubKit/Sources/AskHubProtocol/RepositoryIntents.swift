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
