@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    /// 片付けの意図は封筒に repo を持たないので、例を読むときは repo を外して読む
    static let cleanupKinds: [Kind] = [
        Kind(vectors: "payloads/findCleanupCandidates.json", kind: "findCleanupCandidates", target: nil, targetVersion: nil) {
            try FindCleanupCandidatesIntent(envelope: CleanupIntentsTests.withoutRepository($0)).payload
        },
        Kind(vectors: "payloads/removeCleanupCandidates.json", kind: "removeCleanupCandidates", target: nil, targetVersion: nil) {
            try RemoveCleanupCandidatesIntent(envelope: CleanupIntentsTests.withoutRepository($0)).payload
        }
    ]
}

/// 片付けの候補を探す・消す意図: 封筒に repo・target・targetVersion を持たず、消すのは候補の id だけ
struct CleanupIntentsTests {
    static func withoutRepository(_ envelope: IntentEnvelope) -> IntentEnvelope {
        var envelope = envelope
        envelope.repo = nil
        return envelope
    }

    private func envelope(kind: String, repo: RepositoryFullName? = nil, payload: [String: JSONValue]) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: repo,
            target: nil,
            targetVersion: nil,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-18T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsMacAndCandidatesAndRefusesRepository() throws {
        let mac: [String: JSONValue] = ["mac": .string("macbook-a")]
        let find = try FindCleanupCandidatesIntent(envelope: envelope(kind: "findCleanupCandidates", payload: mac))
        #expect(find.mac.rawValue == "macbook-a")
        #expect(find.intent.nonce.rawValue == "01JCN0NCE00000000000000001")
        let payload: [String: JSONValue] = [
            "mac": .string("macbook-a"), "scannedAt": .string("2026-11-18T10:05:00Z"), "candidates": .array([.string("0123456789abcdef")])
        ]
        let remove = try RemoveCleanupCandidatesIntent(envelope: envelope(kind: "removeCleanupCandidates", payload: payload))
        #expect(remove.candidates == ["0123456789abcdef"])
        #expect(remove.scannedAt.rawValue == "2026-11-18T10:05:00Z")
        // リポジトリの意図ではないので、repo があれば読まない
        let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")
        #expect(throws: MalformedIntent.self) {
            try FindCleanupCandidatesIntent(envelope: envelope(kind: "findCleanupCandidates", repo: repo, payload: mac))
        }
        #expect(throws: MalformedIntent.self) {
            try RemoveCleanupCandidatesIntent(envelope: envelope(kind: "findCleanupCandidates", payload: payload))
        }
    }

    /// 型だけでは表せない決まり: 探す頼みに候補を書かない、消す頼みには候補と探した時刻が要る、記録の数の上限
    @Test func filesCheckRelations() {
        let key = KeyID(rawValue: String(repeating: "k", count: 43))!
        let intent = IntentReference(keyId: key, nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!)
        let time = Timestamp(rawValue: "2026-11-18T10:00:00Z")!
        let find = CleanupRequestsFile.Request(intent: intent, action: .find, candidates: ["0123456789abcdef"], acceptedAt: time)
        #expect(!CleanupRequestsFile(requests: [find]).violations.isEmpty)
        let remove = CleanupRequestsFile.Request(
            intent: intent, action: .remove, candidates: ["0123456789abcdef"], scannedAt: time, acceptedAt: time
        )
        #expect(CleanupRequestsFile(requests: [remove]).violations.isEmpty)
        let tooMany = Array(repeating: remove, count: CleanupRequestsFile.keptRequests + 1)
        #expect(!CleanupRequestsFile(requests: tooMany).violations.isEmpty)
        let negative = CleanupCandidatesFile.Candidate(id: "0123456789abcdef", kind: .clone, name: "a", location: "~/a", bytes: -1)
        #expect(!CleanupCandidatesFile(mac: MacName(rawValue: "mac-mini")!, candidates: [negative]).violations.isEmpty)
    }
}
