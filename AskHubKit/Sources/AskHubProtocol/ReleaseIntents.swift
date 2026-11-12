import Foundation

/// App Store で配信した版を対象にする人の意図の対象。`target` は `{type: release, id: <版>}`、`targetVersion` は人が見たときのリリース文の版
/// （`releases/<版>.json` の `notes.version`）
public struct ReleaseTarget: Equatable, Sendable {
    public static let targetType = "release"

    public var repo: RepositoryFullName
    public var version: MarketingVersion
    public var notesVersion: Int

    public init(repo: RepositoryFullName, version: MarketingVersion, notesVersion: Int) {
        self.repo = repo
        self.version = version
        self.notesVersion = notesVersion
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, target.epic == nil,
              let version = target.id.flatMap(MarketingVersion.init(rawValue:)) else {
            throw .init(detail: "target が配信した版でない")
        }
        guard let notesVersion = envelope.targetVersion.flatMap(AnswerIntent.version) else {
            throw .init(detail: "targetVersion がリリース文の版でない")
        }
        self.init(repo: repo, version: version, notesVersion: notesVersion)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, id: version.rawValue) }
    public var targetVersion: String { String(notesVersion) }
}

/// リリース文を確かめて GitHub Release を公開する人の意図（`kind` が `publishGitHubRelease`）。
/// `notes` は公開する本文（下書きのままでも、人が直したものでもよい）。司令塔は、配信した版のタグを作った後で、この本文で GitHub Release を公開する
public struct PublishGitHubReleaseIntent: Equatable, Sendable {
    public static let kind = "publishGitHubRelease"
    /// 本文の長さの上限（Unicode のコードポイント。GitHub Release の本文の上限より十分に小さい）
    public static let notesLimit = 20_000

    public var target: ReleaseTarget
    public var notes: String
    public var intent: IntentReference

    public init(target: ReleaseTarget, notes: String, intent: IntentReference) {
        self.target = target
        self.notes = notes
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が publishGitHubRelease でない") }
        let target = try ReleaseTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["notes"])
        let notes = try reader.text("notes", required: true, limit: Self.notesLimit)
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .init(detail: "notes が空白だけ") }
        self.init(target: target, notes: notes, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["notes": .string(notes)] }
}
