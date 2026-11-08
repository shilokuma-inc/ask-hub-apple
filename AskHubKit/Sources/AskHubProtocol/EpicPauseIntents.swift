import Foundation

// 開始した epic の一時停止・再開・ほかの Mac への引き継ぎの人の意図（`docs/renewal/operations.md` の「Mac の一時停止・再開・引き継ぎ」）。
// `target` は `{type: epic, epic}`。どれも epic の今の状態に対してだけ意味を持つので、`targetVersion` は書かない

/// 一時停止の人の意図（`kind` が `pauseEpic`）。動いているジョブは最後まで終わらせ、次のジョブを作らない。payload は持たない
public struct PauseEpicIntent: Equatable, Sendable {
    public static let kind = "pauseEpic"

    public var repo: RepositoryFullName
    public var epic: ULID
    public var intent: IntentReference

    public init(repo: RepositoryFullName, epic: ULID, intent: IntentReference) {
        self.repo = repo
        self.epic = epic
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (repo, epic) = try EpicSubject.read(envelope, kind: Self.kind)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(repo: repo, epic: epic, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: EpicTarget.targetType, epic: epic) }
    public var payload: [String: JSONValue] { [:] }
}

/// 再開の人の意図（`kind` が `resumeEpic`）。一時停止の印を外し、一時停止で止めたジョブを戻す。payload は持たない
public struct ResumeEpicIntent: Equatable, Sendable {
    public static let kind = "resumeEpic"

    public var repo: RepositoryFullName
    public var epic: ULID
    public var intent: IntentReference

    public init(repo: RepositoryFullName, epic: ULID, intent: IntentReference) {
        self.repo = repo
        self.epic = epic
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (repo, epic) = try EpicSubject.read(envelope, kind: Self.kind)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(repo: repo, epic: epic, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: EpicTarget.targetType, epic: epic) }
    public var payload: [String: JSONValue] { [:] }
}

/// ほかの Mac への引き継ぎの人の意図（`kind` が `handover`）。`mac` は移す先の Mac（オフラインでもよい）
public struct HandoverIntent: Equatable, Sendable {
    public static let kind = "handover"

    public var repo: RepositoryFullName
    public var epic: ULID
    /// 移す先の Mac
    public var mac: MacName
    public var intent: IntentReference

    public init(repo: RepositoryFullName, epic: ULID, mac: MacName, intent: IntentReference) {
        self.repo = repo
        self.epic = epic
        self.mac = mac
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let (repo, epic) = try EpicSubject.read(envelope, kind: Self.kind)
        let reader = try PayloadReader(envelope.payload, allowed: ["mac"])
        guard let mac = MacName(rawValue: try reader.text("mac", required: true, limit: 32)) else { throw .init(detail: "mac の形が違う") }
        self.init(repo: repo, epic: epic, mac: mac, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target { .init(type: EpicTarget.targetType, epic: epic) }
    public var payload: [String: JSONValue] { ["mac": .string(mac.rawValue)] }
}

/// 版を持たずに epic を対象にする意図（`target` が `{type: epic, epic}`、`targetVersion` なし）の対象の読み方
enum EpicSubject {
    static func read(_ envelope: IntentEnvelope, kind: String) throws(MalformedIntent) -> (RepositoryFullName, ULID) {
        guard envelope.kind == kind else { throw .init(detail: "kind が \(kind) でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == EpicTarget.targetType, let epic = target.epic, target.id == nil else {
            throw .init(detail: "target が epic でない")
        }
        guard envelope.targetVersion == nil else { throw .init(detail: "\(kind) に targetVersion がある") }
        return (repo, epic)
    }
}
