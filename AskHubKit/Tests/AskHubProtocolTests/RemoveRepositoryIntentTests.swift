@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let repositoryKinds: [Kind] = [
        Kind(vectors: "payloads/removeRepository.json", kind: "removeRepository", target: nil, targetVersion: nil) {
            try RemoveRepositoryIntent(envelope: $0).payload
        }
    ]
}

/// 対象から外す: 封筒の repo だけを持ち、外した印は repo.json の removedAt に付ける
struct RemoveRepositoryIntentTests {
    private func envelope(
        target: IntentEnvelope.Target? = nil,
        targetVersion: String? = nil,
        payload: [String: JSONValue]? = nil
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: "removeRepository",
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"),
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-12T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test func readsRepositoryAndRefusesTargets() throws {
        #expect(try RemoveRepositoryIntent(envelope: envelope()).repo.rawValue == "shilokuma-inc/askhub-sandbox")
        #expect(try RemoveRepositoryIntent(envelope: envelope(payload: [:])).payload.isEmpty)
        #expect(throws: MalformedIntent.self) {
            try RemoveRepositoryIntent(envelope: envelope(target: .init(type: "epic", epic: EpicIntentsTests.epic)))
        }
        #expect(throws: MalformedIntent.self) {
            try RemoveRepositoryIntent(envelope: envelope(targetVersion: "1"))
        }
    }

    @Test func repositoryFileKeepsRemovedMark() throws {
        let removed = Timestamp(rawValue: "2026-11-12T10:00:00Z")!
        var file = RepositoryFile(
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!,
            platform: .apple,
            addedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!
        )
        #expect(!file.isRemoved)
        // 外していないときは書かない（今までのファイルと同じ形）
        #expect(String(bytes: try StateFileCoder.encode(file), encoding: .utf8)?.contains("removedAt") == false)
        file.removedAt = removed
        let read = try StateFileCoder.decode(RepositoryFile.self, from: StateFileCoder.encode(file))
        #expect(read.removedAt == removed)
        #expect(read.isRemoved)
    }
}
