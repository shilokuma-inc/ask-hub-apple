import Foundation

/// 依頼の添付の 1 つ（中身は `attachments/<device>/<nonce>/<n>`）
public struct RequestAttachment: Codable, Equatable, Sendable {
    public var number: Int
    public var name: String
    public var size: Int
    /// 中身の SHA-256（16 進の小文字 64 文字）
    public var sha256: String

    enum CodingKeys: String, CodingKey {
        case number = "n"
        case name, size, sha256
    }

    public init(number: Int, name: String, size: Int, sha256: String) {
        self.number = number
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// 依頼の人の意図（`kind` が `request`）
public struct RequestIntent: Equatable, Sendable {
    public static let kind = "request"
    public static let maximumTitleLength = 200
    public static let maximumBodyLength = 20000
    public static let maximumAttachments = 10
    /// 添付 1 つの大きさの上限（GitHub の Contents API で 1 つのファイルとして読み書きできる大きさ）
    public static let maximumAttachmentBytes = 50 * 1024 * 1024

    public var repo: RepositoryFullName
    public var title: String
    public var body: String
    public var attachments: [RequestAttachment]
    public var intent: IntentReference

    public init(repo: RepositoryFullName, title: String, body: String, attachments: [RequestAttachment] = [], intent: IntentReference) {
        self.repo = repo
        self.title = title
        self.body = body
        self.attachments = attachments
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が request でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        // 依頼は版を持つものを対象にしないので、targetVersion を書かない
        guard envelope.targetVersion == nil else { throw .init(detail: "依頼に targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["title", "body", "attachments"])
        self.init(
            repo: repo,
            title: try reader.text("title", required: true, limit: Self.maximumTitleLength),
            body: try reader.text("body", required: false, limit: Self.maximumBodyLength),
            attachments: try Self.readAttachments(reader.payload["attachments"]),
            intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        )
    }

    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = ["title": .string(title)]
        if !body.isEmpty { payload["body"] = .string(body) }
        if !attachments.isEmpty {
            payload["attachments"] = .array(attachments.map { attachment in
                .object([
                    "n": .integer(Int64(attachment.number)),
                    "name": .string(attachment.name),
                    "size": .integer(Int64(attachment.size)),
                    "sha256": .string(attachment.sha256)
                ])
            })
        }
        return payload
    }

    /// 番号は 1 から順に。名前はパスの区切りを含まない。ハッシュは 16 進の小文字
    private static func readAttachments(_ value: JSONValue?) throws(MalformedIntent) -> [RequestAttachment] {
        guard let value else { return [] }
        guard case let .array(items) = value, items.count <= maximumAttachments else { throw .init(detail: "attachments が配列でない・多すぎる") }
        var attachments: [RequestAttachment] = []
        for (index, item) in items.enumerated() {
            guard case let .object(fields) = item, Set(fields.keys) == ["n", "name", "size", "sha256"],
                  let number = fields["n"]?.integerValue, number == Int64(index + 1),
                  let name = fields["name"]?.stringValue, isAttachmentName(name),
                  let size = fields["size"]?.integerValue, (1...Int64(maximumAttachmentBytes)).contains(size),
                  let sha256 = fields["sha256"]?.stringValue, isSHA256(sha256) else {
                throw .init(detail: "attachments の \(index + 1) 番目の形が違う")
            }
            attachments.append(RequestAttachment(number: Int(number), name: name, size: Int(size), sha256: sha256))
        }
        return attachments
    }

    private static func isAttachmentName(_ name: String) -> Bool {
        (1...200).contains(name.unicodeScalars.count) && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

/// epic を対象にする人の意図の共通の部分（`target` が `{type: epic, epic}`）
public struct EpicTarget: Equatable, Sendable {
    public static let targetType = "epic"

    public var repo: RepositoryFullName
    public var epic: ULID
    /// 確かめた対象の版（`targetVersion`）。開始・ゴールの修正ではゴールの版、分け方の判断では着手前の確認の結果の版
    public var version: Int

    public init(repo: RepositoryFullName, epic: ULID, version: Int) {
        self.repo = repo
        self.epic = epic
        self.version = version
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic, target.id == nil else {
            throw .init(detail: "target が epic でない")
        }
        guard let version = envelope.targetVersion.flatMap(AnswerIntent.version) else { throw .init(detail: "targetVersion が対象の版でない") }
        self.init(repo: repo, epic: epic, version: version)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic) }
    public var targetVersion: String { String(version) }
}

/// 開始の人の意図（`kind` が `startEpic`）
public struct StartEpicIntent: Equatable, Sendable {
    public static let kind = "startEpic"

    public var target: EpicTarget
    /// 回す Mac
    public var mac: MacName
    public var intent: IntentReference

    public init(target: EpicTarget, mac: MacName, intent: IntentReference) {
        self.target = target
        self.mac = mac
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が startEpic でない") }
        let target = try EpicTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["mac"])
        guard let mac = MacName(rawValue: try reader.text("mac", required: true, limit: 32)) else { throw .init(detail: "mac の形が違う") }
        self.init(target: target, mac: mac, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["mac": .string(mac.rawValue)] }
}

/// ゴールの修正の人の意図（`kind` が `reviseGoal`）
public struct ReviseGoalIntent: Equatable, Sendable {
    public static let kind = "reviseGoal"
    public static let maximumInstructionLength = 10000

    public var target: EpicTarget
    public var instruction: String
    public var intent: IntentReference

    public init(target: EpicTarget, instruction: String, intent: IntentReference) {
        self.target = target
        self.instruction = instruction
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が reviseGoal でない") }
        let target = try EpicTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["instruction"])
        self.init(
            target: target,
            instruction: try reader.text("instruction", required: true, limit: Self.maximumInstructionLength),
            intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        )
    }

    public var payload: [String: JSONValue] { ["instruction": .string(instruction)] }
}

/// 分け方の判断の人の意図（`kind` が `decideSplit`）。`targetVersion` は着手前の確認の結果（`readiness.json`）の版
public struct DecideSplitIntent: Equatable, Sendable {
    public enum Choice: String, Sendable, CaseIterable {
        /// 今の epic をやめる。分け方の案ごとの依頼は、人がクライアントで出し直す
        case split
        /// このまま 1 つの epic で進める（着手前の確認をやり直して、ゴールを作る）
        case proceed
    }

    public static let kind = "decideSplit"

    public var target: EpicTarget
    public var choice: Choice
    public var intent: IntentReference

    public init(target: EpicTarget, choice: Choice, intent: IntentReference) {
        self.target = target
        self.choice = choice
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が decideSplit でない") }
        let target = try EpicTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["choice"])
        guard let choice = Choice(rawValue: try reader.text("choice", required: true, limit: 16)) else {
            throw .init(detail: "choice が split・proceed のどちらでもない")
        }
        self.init(target: target, choice: choice, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["choice": .string(choice.rawValue)] }
}
