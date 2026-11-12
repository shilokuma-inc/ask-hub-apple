@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let protectionKinds: [Kind] = [
        Kind(vectors: "payloads/applyProtection.json", kind: "applyProtection", target: nil, targetVersion: nil) {
            try ApplyProtectionIntent(envelope: $0).payload
        }
    ]
}

/// 保護の設定の人の意図（`applyProtection`）と、`repo.json` の `protection`
struct ProtectionProtocolTests {
    private func envelope(
        payload: [String: JSONValue],
        target: IntentEnvelope.Target? = nil,
        repo: String? = "shilokuma-inc/askhub-sandbox"
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: ApplyProtectionIntent.kind,
            repo: repo.flatMap(RepositoryFullName.init(rawValue:)),
            target: target,
            targetVersion: nil,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-13T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsRequiredChecksInOrder() throws {
        let payload: [String: JSONValue] = ["requiredChecks": .array([.string("build / build"), .string("lint")])]
        let intent = try ApplyProtectionIntent(envelope: envelope(payload: payload))
        #expect(intent.requiredChecks == ["build / build", "lint"])
        #expect(intent.repo.rawValue == "shilokuma-inc/askhub-sandbox")
        #expect(intent.payload == ["requiredChecks": .array([.string("build / build"), .string("lint")])])
    }

    @Test func refusesTargetAndMissingRepository() {
        let payload: [String: JSONValue] = ["requiredChecks": .array([.string("build / build")])]
        #expect(throws: MalformedIntent.self) { try ApplyProtectionIntent(envelope: envelope(payload: payload, repo: nil)) }
        #expect(throws: MalformedIntent.self) {
            try ApplyProtectionIntent(envelope: envelope(payload: payload, target: .init(type: "epic", epic: EpicIntentsTests.epic)))
        }
    }

    @Test(arguments: [
        [String](),
        ["build / build", "build / build"],
        [" "],
        ["build\n"],
        [String(repeating: "a", count: 201)],
        (1...21).map { "check-\($0)" }
    ])
    func refusesMalformedRequiredChecks(_ checks: [String]) {
        #expect(!ProtectionPolicy.problems(ofRequiredChecks: checks).isEmpty)
        #expect(throws: MalformedIntent.self) {
            try ApplyProtectionIntent(envelope: envelope(payload: ["requiredChecks": .array(checks.map(JSONValue.string))]))
        }
    }

    @Test func policyProtectsDevelopMainAndReleaseBranches() {
        #expect(ProtectionPolicy.rulesetName == "askhub-protect")
        #expect(ProtectionPolicy.branches == ["develop", "main", "release/**"])
        #expect(ProtectionPolicy.defaultRequiredChecks == ["build / build"])
        #expect(ProtectionPolicy.problems(ofRequiredChecks: ProtectionPolicy.defaultRequiredChecks).isEmpty)
    }

    /// 書き直して読み直すだけでは、読み落とした欄に気づけないので、読んだ値を直接確かめる
    @Test func readsAppliedProtection() throws {
        let vectors = try #require(try JSONSerialization.jsonObject(with: Vectors.data("state/repo.json")) as? [String: Any])
        let cases = try #require(vectors["cases"] as? [[String: Any]])
        let value = try #require(cases.first { $0["name"] as? String == "protection-applied" }?["value"])
        let protection = try StateFileCoder.decode(RepositoryFile.self, from: JSONSerialization.data(withJSONObject: value)).protection
        #expect(protection.appliedAt?.rawValue == "2026-11-13T10:00:00Z")
        #expect(protection.requiredChecks == ["build / build"])
        #expect(protection.rulesetId == 26_926_767)
        #expect(protection.replaced == [.init(kind: .classic, name: "develop"), .init(kind: .ruleset, name: "protect-develop")])
        #expect(protection.remaining == [.init(kind: .organizationRuleset, name: "org-default")])
        #expect(protection.drift?.problems == ["必須のチェックが変わった（今は 無し）"])
        #expect(protection.drift?.foundAt.rawValue == "2026-11-14T04:00:00Z")
    }
}
