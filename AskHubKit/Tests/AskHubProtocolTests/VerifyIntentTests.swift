@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let verificationTarget = IntentEnvelope.Target(type: "verification", epic: epic, id: "v2")
    static let verifyKinds: [Kind] = [
        Kind(vectors: "payloads/verify.json", kind: "verify", target: verificationTarget, targetVersion: "3") {
            try VerifyIntent(envelope: $0).payload
        }
    ]
}

/// 実機確認への答え: 項目はゴールの完了の条件を v1 から数えたもので、ゴールの版に結びつく
struct VerifyIntentTests {
    private func envelope(target: IntentEnvelope.Target?, targetVersion: String?, payload: [String: JSONValue]) -> IntentEnvelope {
        IntentEnvelope(
            kind: "verify",
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"),
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-12T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsTargetAndGoalVersion() throws {
        let intent = try VerifyIntent(envelope: envelope(
            target: EpicIntentsTests.verificationTarget,
            targetVersion: "3",
            payload: ["result": .string("problem"), "note": .string("線が見えない")]
        ))
        #expect(intent.target.item == "v2")
        #expect(intent.target.goalVersion == 3)
        #expect(intent.result == .problem)
        #expect(intent.note == "線が見えない")
        #expect(intent.target.target == EpicIntentsTests.verificationTarget)
        #expect(intent.target.targetVersion == "3")
    }

    @Test func refusesWrongTargets() {
        let payload: [String: JSONValue] = ["result": .string("confirmed")]
        let epic = EpicIntentsTests.epic
        let wrongTargets: [(IntentEnvelope.Target?, String?)] = [
            (nil, "3"),
            (.init(type: "humanTask", epic: epic, id: "v1"), "3"),
            (.init(type: "verification", epic: epic, id: "v0"), "3"),
            (.init(type: "verification", epic: epic, id: "v01"), "3"),
            (.init(type: "verification", epic: epic, id: "d1"), "3"),
            (.init(type: "verification", epic: epic), "3"),
            (EpicIntentsTests.verificationTarget, nil),
            (EpicIntentsTests.verificationTarget, "03")
        ]
        for (target, version) in wrongTargets {
            #expect(throws: MalformedIntent.self, "\(String(describing: target)) \(String(describing: version))") {
                try VerifyIntent(envelope: envelope(target: target, targetVersion: version, payload: payload))
            }
        }
    }

    @Test func itemIDsFollowDoneWhenOrder() {
        #expect(VerificationTarget.itemID(at: 0) == "v1")
        #expect(VerificationTarget.index(of: "v12") == 11)
        #expect(VerificationTarget.index(of: "v1000") == nil)
        #expect(VerificationTarget.index(of: "v+1") == nil)
        #expect(VerificationTarget.index(of: "V1") == nil)
    }
}
