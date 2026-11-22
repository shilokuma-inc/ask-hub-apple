import Foundation

/// 人がする作業を対象にする人の意図の対象。`target` は `{type: humanTask, epic, id: <作業の id>}`、`targetVersion` は人が見たときのゴールの版
public struct HumanTaskTarget: Equatable, Sendable {
    public static let targetType = "humanTask"

    public var repo: RepositoryFullName
    public var epic: ULID
    /// ゴールの人がする作業の id（`h1` など）
    public var task: String
    public var goalVersion: Int

    public init(repo: RepositoryFullName, epic: ULID, task: String, goalVersion: Int) {
        self.repo = repo
        self.epic = epic
        self.task = task
        self.goalVersion = goalVersion
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic, let task = target.id,
              LocalIDs.isValid(task) else {
            throw .init(detail: "target が人がする作業でない")
        }
        guard let version = envelope.targetVersion.flatMap(AnswerIntent.version) else { throw .init(detail: "targetVersion がゴールの版でない") }
        self.init(repo: repo, epic: epic, task: task, goalVersion: version)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic, id: task) }
    public var targetVersion: String { String(goalVersion) }
}

/// 人がする作業を終えた人の意図（`kind` が `humanTaskDone`）。「終わった」なら payload は空、ファイルを渡すなら `attachments` に 1 つ
/// （依頼の添付と同じ形・同じ置き場所 `attachments/<device>/<nonce>/<n>`・同じ上限）、GitHub の Secrets に入れるなら `secret` に暗号文
/// （クライアントがリポジトリの公開鍵で暗号化したもの。平文は入れない）
public struct HumanTaskDoneIntent: Equatable, Sendable {
    public static let kind = "humanTaskDone"

    public var target: HumanTaskTarget
    public var file: RequestAttachment?
    public var secret: EncryptedSecret?
    public var intent: IntentReference

    public init(target: HumanTaskTarget, file: RequestAttachment? = nil, secret: EncryptedSecret? = nil, intent: IntentReference) {
        self.target = target
        self.file = file
        self.secret = secret
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が humanTaskDone でない") }
        let target = try HumanTaskTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["attachments", "secret"])
        let files = try RequestIntent.readAttachments(reader.payload["attachments"])
        guard files.count <= 1 else { throw .init(detail: "渡すファイルは 1 つまで") }
        let secret = try Self.secret(reader.payload["secret"])
        guard files.isEmpty || secret == nil else { throw .init(detail: "ファイルと secret を一緒に渡せない") }
        self.init(target: target, file: files.first, secret: secret, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] {
        if let secret { return ["secret": secret.jsonValue] }
        return file.map { ["attachments": .array([$0.jsonValue])] } ?? [:]
    }

    /// `secret` の欄（`keyId` と `encryptedValue` だけ）。無ければ nil
    private static func secret(_ value: JSONValue?) throws(MalformedIntent) -> EncryptedSecret? {
        guard let value else { return nil }
        guard case let .object(fields) = value, Set(fields.keys) == ["keyId", "encryptedValue"],
              case let .string(keyId)? = fields["keyId"], case let .string(encrypted)? = fields["encryptedValue"] else {
            throw .init(detail: "secret は keyId と encryptedValue だけを持つ")
        }
        let secret = EncryptedSecret(keyId: keyId, encryptedValue: encrypted)
        if let problem = secret.problem { throw .init(detail: problem) }
        return secret
    }
}
