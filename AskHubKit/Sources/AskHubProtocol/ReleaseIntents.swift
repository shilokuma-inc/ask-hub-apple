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

/// 配信中の版のプロモーションテキストを直す人の意図（`kind` が `updatePromotionalText`）。`target` は `{type: release, id: <版>}` で、
/// `targetVersion` は持たない。`texts` は書く文（変える言語だけ。空の文字列は空にする）。審査に出さずに変えられるので、司令塔がすぐ App Store Connect に書く
public struct UpdatePromotionalTextIntent: Equatable, Sendable {
    public static let kind = "updatePromotionalText"

    public var repo: RepositoryFullName
    public var version: MarketingVersion
    public var texts: [LocalizedText]
    public var intent: IntentReference

    public init(repo: RepositoryFullName, version: MarketingVersion, texts: [LocalizedText], intent: IntentReference) {
        self.repo = repo
        self.version = version
        self.texts = texts
        self.intent = intent
    }

    private struct Payload: Codable {
        var texts: [LocalizedText]
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が updatePromotionalText でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == ReleaseTarget.targetType, target.epic == nil,
              let version = target.id.flatMap(MarketingVersion.init(rawValue:)) else {
            throw .init(detail: "target が配信した版でない")
        }
        guard envelope.targetVersion == nil else { throw .init(detail: "updatePromotionalText に targetVersion がある") }
        let value = JSONValue.object(envelope.payload ?? [:])
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: CanonicalJSON.data(for: value))
        } catch {
            throw .init(detail: "payload の形が違う（\(error)）")
        }
        // 読んだ値を書き直したものに、送られた値がすべて含まれる（綴りの誤りなど、読み飛ばした欄が無い）
        guard let encoded = try? JSONValue(parsing: JSONEncoder().encode(payload)), value.isContained(in: encoded) else {
            throw .init(detail: "payload に知らない欄がある")
        }
        if payload.texts.isEmpty { throw .init(detail: "texts が空") }
        let problems = ReleaseFile.promotionalTextProblems(of: payload.texts, name: "texts")
        if !problems.isEmpty { throw .init(detail: problems.joined(separator: "、")) }
        self.init(repo: repo, version: version, texts: payload.texts, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: ReleaseTarget.targetType, id: version.rawValue) }

    public var payload: [String: JSONValue] { Self.payload(texts: texts) }

    /// 送る payload（クライアントが作る）
    public static func payload(texts: [LocalizedText]) -> [String: JSONValue] {
        guard case let .object(fields)? = (try? JSONEncoder().encode(Payload(texts: texts))).flatMap({ try? JSONValue(parsing: $0) }) else {
            return [:]
        }
        return fields
    }
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
