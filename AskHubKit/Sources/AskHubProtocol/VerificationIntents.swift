import Foundation

/// 実機確認の項目を対象にする人の意図の対象。`target` は `{type: verification, epic, id: <項目の id>}`、`targetVersion` は人が見たときのゴールの版。
///
/// 項目は、ゴールの完了の条件（`doneWhen`）を順に `v1`・`v2`… と数えたもの（最終 PR の本文の「実機で確かめてほしいこと」と同じ。
/// `docs/renewal/flows.md` の「実機で確かめてほしいこと」）
public struct VerificationTarget: Equatable, Sendable {
    public static let targetType = "verification"

    public var repo: RepositoryFullName
    public var epic: ULID
    /// 項目の id（`v1` など）
    public var item: String
    public var goalVersion: Int

    public init(repo: RepositoryFullName, epic: ULID, item: String, goalVersion: Int) {
        self.repo = repo
        self.epic = epic
        self.item = item
        self.goalVersion = goalVersion
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic, let item = target.id,
              Self.index(of: item) != nil else {
            throw .init(detail: "target が実機確認の項目でない")
        }
        guard let version = envelope.targetVersion.flatMap(AnswerIntent.version) else { throw .init(detail: "targetVersion がゴールの版でない") }
        self.init(repo: repo, epic: epic, item: item, goalVersion: version)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic, id: item) }
    public var targetVersion: String { String(goalVersion) }

    /// 完了の条件の添字（0 から）の項目の id
    public static func itemID(at index: Int) -> String {
        "v\(index + 1)"
    }

    /// 項目の id が指す完了の条件の添字（0 から）。形が違えば nil（`v` に続けて、0 で始まらない 1〜3 桁の数）
    public static func index(of item: String) -> Int? {
        guard item.hasPrefix("v"), let number = Int(item.dropFirst()), (1...999).contains(number), item == itemID(at: number - 1) else {
            return nil
        }
        return number - 1
    }
}

/// 実機確認への答え（`kind` が `verify`）。マージした epic の項目に「確認した」「問題あり」を付ける。「問題あり」は問題の説明（`note`）が要り、「確認した」は持たない。
///
/// この意図は答えを記録するだけにする。「問題あり」の直しは、クライアントが同時に送る依頼（`request`）で頼む
public struct VerifyIntent: Equatable, Sendable {
    public static let kind = "verify"
    public static let maximumNoteLength = 10000

    public enum Result: String, Codable, Sendable, CaseIterable {
        /// 確認した
        case confirmed
        /// 問題あり
        case problem
    }

    public var target: VerificationTarget
    public var result: Result
    public var note: String
    public var intent: IntentReference

    public init(target: VerificationTarget, result: Result, note: String = "", intent: IntentReference) {
        self.target = target
        self.result = result
        self.note = note
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が verify でない") }
        let target = try VerificationTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["result", "note"])
        guard let result = Result(rawValue: try reader.text("result", required: true, limit: 16)) else {
            throw .init(detail: "result が confirmed・problem のどちらでもない")
        }
        // 問題ありは、何が起きたかが無いと直せない。確認したは説明を持たない（記録の `note` を空にそろえる）
        let note = try reader.text("note", required: result == .problem, limit: Self.maximumNoteLength)
        guard result == .problem || note.isEmpty else { throw .init(detail: "確認したに note がある") }
        self.init(target: target, result: result, note: note, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = ["result": .string(result.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return payload
    }
}
