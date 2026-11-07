import Foundation

/// 最終 PR を対象にする人の意図の対象。`target` は `{type: finalPullRequest, epic}`、`targetVersion` は人が見たときの最終 PR の head のコミット。
/// 見た後に push された変更には効かない（承認は、その時点の head に結びつく。`docs/renewal/flows.md` の「マージの規則」）
public struct FinalPullRequestTarget: Equatable, Sendable {
    public static let targetType = "finalPullRequest"

    public var repo: RepositoryFullName
    public var epic: ULID
    public var head: String

    public init(repo: RepositoryFullName, epic: ULID, head: String) {
        self.repo = repo
        self.epic = epic
        self.head = head
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic, target.id == nil else {
            throw .init(detail: "target が最終 PR でない")
        }
        guard let head = envelope.targetVersion, AttemptFile.isCommitSHA(head) else { throw .init(detail: "targetVersion が head のコミットでない") }
        self.init(repo: repo, epic: epic, head: head)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic) }
    public var targetVersion: String { head }
}

/// 判断のカード（`decisions.json` の項目）を対象にする人の意図の対象。`target` は `{type: decision, epic, id: <項目の id>}`、`targetVersion` は最終 PR の head
public struct DecisionTarget: Equatable, Sendable {
    public static let targetType = "decision"

    public var repo: RepositoryFullName
    public var epic: ULID
    public var decision: String
    public var head: String

    public init(repo: RepositoryFullName, epic: ULID, decision: String, head: String) {
        self.repo = repo
        self.epic = epic
        self.decision = decision
        self.head = head
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic,
              let decision = target.id, LocalIDs.isValid(decision) else {
            throw .init(detail: "target が判断のカードでない")
        }
        guard let head = envelope.targetVersion, AttemptFile.isCommitSHA(head) else { throw .init(detail: "targetVersion が head のコミットでない") }
        self.init(repo: repo, epic: epic, decision: decision, head: head)
    }

    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic, id: decision) }
    public var targetVersion: String { head }
}

/// 判断のカードへの答え（`kind` が `decision`）。「別案にする」「直してほしい」は本文（`note`）が要る
public struct DecisionIntent: Equatable, Sendable {
    public static let kind = "decision"
    public static let maximumNoteLength = 10000

    public var target: DecisionTarget
    public var answer: DecisionsFile.Choice
    public var note: String
    public var intent: IntentReference

    public init(target: DecisionTarget, answer: DecisionsFile.Choice, note: String = "", intent: IntentReference) {
        self.target = target
        self.answer = answer
        self.note = note
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が decision でない") }
        let target = try DecisionTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["answer", "note"])
        guard let answer = DecisionsFile.Choice(rawValue: try reader.text("answer", required: true, limit: 16)) else {
            throw .init(detail: "answer が ok・alternative・fix のどれでもない")
        }
        // 別案・直してほしいは、何をどうしてほしいかが無いと直せない
        let note = try reader.text("note", required: answer != .ok, limit: Self.maximumNoteLength)
        self.init(target: target, answer: answer, note: note, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = ["answer": .string(answer.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return payload
    }
}

/// 最終 PR のマージの承認（`kind` が `approveMerge`）。見える仮決めにすべて答えた後でだけ受け付ける。payload は持たない
public struct ApproveMergeIntent: Equatable, Sendable {
    public static let kind = "approveMerge"

    public var target: FinalPullRequestTarget
    public var intent: IntentReference

    public init(target: FinalPullRequestTarget, intent: IntentReference) {
        self.target = target
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が approveMerge でない") }
        let target = try FinalPullRequestTarget(envelope: envelope)
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(target: target, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}

/// 最終 PR への指示（`kind` が `instructFinal`）。Claude に直させ、最終 PR のレビューからやり直す
public struct InstructFinalIntent: Equatable, Sendable {
    public static let kind = "instructFinal"
    public static let maximumInstructionLength = 10000

    public var target: FinalPullRequestTarget
    public var instruction: String
    public var intent: IntentReference

    public init(target: FinalPullRequestTarget, instruction: String, intent: IntentReference) {
        self.target = target
        self.instruction = instruction
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が instructFinal でない") }
        let target = try FinalPullRequestTarget(envelope: envelope)
        let reader = try PayloadReader(envelope.payload, allowed: ["instruction"])
        let instruction = try reader.text("instruction", required: true, limit: Self.maximumInstructionLength)
        self.init(target: target, instruction: instruction, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { ["instruction": .string(instruction)] }
}
