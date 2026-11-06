@testable import AskHubProtocol
import Foundation
import Testing

struct AnswerIntentTests {
    private let validator = SchemaValidator(directory: Vectors.directory.deletingLastPathComponent().appendingPathComponent("schemas"))
    private let epic = ULID(rawValue: "01JCEP1C000000000000000001")!

    private func envelope(
        kind: String = "answer",
        target: IntentEnvelope.Target? = nil,
        targetVersion: String? = "1",
        payload: [String: JSONValue]? = ["mode": .string("answer"), "choice": .string("日ごと")]
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"),
            target: target ?? .init(type: "question", epic: epic, id: "q1"),
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func followsPayloadVectors() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data("payloads/answer.json")) as? [String: Any])
        let schema = try #require(file["schema"] as? String)
        let cases = try #require(file["cases"] as? [[String: Any]])
        for vector in cases {
            let name = try #require(vector["name"] as? String)
            let payload = try #require(vector["payload"])
            let errors = try validator.errors(of: payload, against: schema)
            #expect(errors.isEmpty == (vector["schemaValid"] as? Bool), "\(name): \(errors)")
            let value = try JSONValue(parsing: JSONSerialization.data(withJSONObject: payload))
            guard case let .object(object) = value else { Issue.record("\(name): payload が object でない"); continue }
            let read: String
            do {
                let answer = try AnswerIntent(envelope: envelope(payload: object))
                // 読めたものを書き直すと、同じものとして読める
                #expect(try AnswerIntent(envelope: envelope(payload: answer.payload)) == answer, "\(name)")
                let rewritten = try JSONSerialization.jsonObject(with: CanonicalJSON.data(for: .object(answer.payload)))
                #expect(try validator.errors(of: rewritten, against: schema).isEmpty, "\(name) を書き直したもの")
                read = "valid"
            } catch {
                read = "malformed"
            }
            #expect("\(name): \(read)" == "\(name): \(vector["read"] as? String ?? "")")
        }
    }

    @Test func readsTargetAndIntent() throws {
        let answer = try AnswerIntent(envelope: envelope(targetVersion: "12"))
        #expect(answer.epic == epic)
        #expect(answer.question == "q1")
        #expect(answer.questionVersion == 12)
        #expect(answer.intent.nonce.rawValue == "01JCN0NCE00000000000000001")
        #expect(answer.target == .init(type: "question", epic: epic, id: "q1"))
        #expect(answer.targetVersion == "12")
    }

    @Test func rejectsEnvelopeThatIsNotAnAnswer() {
        let cases: [IntentEnvelope] = [
            envelope(kind: "startEpic"),
            envelope(target: .init(type: "epic", epic: epic)),
            envelope(target: .init(type: "question", id: "q1")),
            envelope(target: .init(type: "question", epic: epic)),
            envelope(targetVersion: nil),
            envelope(targetVersion: "0"),
            envelope(targetVersion: "01"),
            envelope(targetVersion: "+1"),
            envelope(targetVersion: "1.0"),
            envelope(payload: nil)
        ]
        for envelope in cases {
            #expect(throws: AnswerIntent.Malformed.self) { try AnswerIntent(envelope: envelope) }
        }
    }
}
