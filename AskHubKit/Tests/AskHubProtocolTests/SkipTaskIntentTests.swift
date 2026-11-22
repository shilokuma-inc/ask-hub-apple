@testable import AskHubProtocol
import Foundation
import Testing

/// タスクを飛ばす人の意図（`skipTask`）の形
struct SkipTaskIntentTests {
    static let epic = EpicIntentsTests.epic
    static let job = EpicIntentsTests.job
    static let target = IntentEnvelope.Target(type: "job", epic: epic, id: job.rawValue)

    private func envelope(
        kind: String = "skipTask",
        target: IntentEnvelope.Target? = target,
        payload: [String: JSONValue]
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"),
            target: target,
            targetVersion: "1",
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    /// 理由とメモを読み、メモの無い（空の）ものは payload に書かない
    @Test func readsReasonAndNote() throws {
        let payload: [String: JSONValue] = ["reason": .string("handledElsewhere"), "note": .string("別の依頼で直す")]
        let skip = try SkipTaskIntent(envelope: envelope(payload: payload))
        #expect(skip.reason == .handledElsewhere)
        #expect(skip.note == "別の依頼で直す")
        #expect(skip.target.attempt == 1)
        #expect(skip.payload == payload)
        let plain = try SkipTaskIntent(envelope: envelope(payload: ["reason": .string("notNeeded"), "note": .string("")]))
        #expect(plain.note.isEmpty)
        #expect(plain.payload == ["reason": .string("notNeeded")])
    }

    /// メモは 2000 文字（Unicode のコードポイント）まで
    @Test func limitsNoteLength() throws {
        let longest = String(repeating: "あ", count: SkipTaskIntent.maximumNoteLength)
        _ = try SkipTaskIntent(envelope: envelope(payload: ["reason": .string("notNeeded"), "note": .string(longest)]))
        #expect(throws: MalformedIntent.self) {
            try SkipTaskIntent(envelope: envelope(payload: ["reason": .string("notNeeded"), "note": .string(longest + "あ")]))
        }
    }

    /// やめると取り違えない・ジョブでない対象は読まない
    @Test func rejectsOtherKindsAndTargets() {
        let payload: [String: JSONValue] = ["reason": .string("notNeeded")]
        #expect(throws: MalformedIntent.self) { try SkipTaskIntent(envelope: envelope(kind: "giveUp", payload: payload)) }
        #expect(throws: MalformedIntent.self) {
            try SkipTaskIntent(envelope: envelope(target: .init(type: "epic", epic: Self.epic), payload: payload))
        }
    }
}
