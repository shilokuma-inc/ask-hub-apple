@testable import AskHubProtocol
import CryptoKit
import Foundation
import Testing

private struct LedgerVectorKey: Decodable {
    let privateKeyRaw: String
    let publicKeyDer: String
    let keyId: String
}

private struct LedgerVectorCase: Decodable {
    let name: String
    let firstKey: String
    let records: [JSONValue]
    let keys: [String]
    let verifiedCount: Int
    let problem: JSONValue?
}

private struct LedgerVectorFile: Decodable {
    let accounts: [String]
    let keys: [String: LedgerVectorKey]
    let cases: [LedgerVectorCase]
}

private struct StoredIntentCase: Decodable {
    let name: String
    let value: JSONValue
    let trustedKeys: [String]
    let now: String
    let result: String
}

private struct StoredIntentFile: Decodable {
    let cases: [StoredIntentCase]
}

struct KeyLedgerTests {
    private typealias File = LedgerVectorFile

    @Test func followsVectors() throws {
        let file = try Vectors.load("key-ledger.json", as: File.self)
        #expect(file.cases.count >= 20)
        let names = try file.keys.mapValues { try #require(KeyID(rawValue: $0.keyId)) }
        for vector in file.cases {
            let firstKey = try #require(names[vector.firstKey])
            let result = KeyLedger.verify(vector.records, firstKey: firstKey, accounts: Set(file.accounts))
            let expectedKeys = try Set(vector.keys.map { try #require(names[$0]) })
            #expect(Set(result.keys.keys) == expectedKeys, "\(vector.name)")
            #expect(result.verifiedCount == vector.verifiedCount, "\(vector.name)")
            #expect(result.problem == Self.problem(vector.problem), "\(vector.name)")
            #expect((vector.problem == nil) == (Self.problem(vector.problem) == nil), "\(vector.name): 例の problem を読めない")
        }
    }

    @Test func registeredKeysCarryAccountAndLabel() throws {
        let file = try Vectors.load("key-ledger.json", as: File.self)
        let vector = try #require(file.cases.first { $0.name == "valid-chain" })
        let key2 = try #require(KeyID(rawValue: file.keys["key2"]?.keyId ?? ""))
        let key1 = try #require(KeyID(rawValue: file.keys["key1"]?.keyId ?? ""))
        let result = KeyLedger.verify(vector.records, firstKey: key1, accounts: Set(file.accounts))
        let registered = try #require(result.keys[key2])
        #expect(registered.account == "askhub-test-account")
        #expect(registered.label == "テスト端末 2")
        #expect(registered.addedAt.rawValue == "2026-11-03T10:01:00Z")
        #expect(Base64URL.encode(registered.publicKeyDER) == file.keys["key2"]?.publicKeyDer)
    }

    /// 自分で作った記録の列が、確かめを通る（クライアントが書く側）
    @Test func signsRecordsThatVerify() throws {
        let file = try Vectors.load("key-ledger.json", as: File.self)
        let first = try Self.privateKey(file.keys["key1"])
        let second = try Self.privateKey(file.keys["key2"])
        let firstID = IntentSignature.keyID(publicKeyDER: first.publicKey.derRepresentation)
        let secondID = IntentSignature.keyID(publicKeyDER: second.publicKey.derRepresentation)
        let time = try #require(Timestamp(rawValue: "2026-11-03T10:00:00Z"))
        let unsigned1 = KeyLedger.Record(
            seq: 1,
            action: .add,
            keyId: firstID,
            publicKey: Base64URL.encode(first.publicKey.derRepresentation),
            account: "askhub-test-account",
            label: "Mac",
            issuedAt: time,
            signedBy: firstID
        )
        let record1 = try KeyLedger.sign(unsigned1) { try first.signature(for: $0) }
        let unsigned2 = KeyLedger.Record(
            seq: 2,
            action: .add,
            keyId: secondID,
            publicKey: Base64URL.encode(second.publicKey.derRepresentation),
            account: "askhub-test-account",
            label: "iPhone",
            issuedAt: time,
            previousSha256: KeyLedger.hash(of: record1),
            signedBy: firstID
        )
        let record2 = try KeyLedger.sign(unsigned2) { try first.signature(for: $0) }
        let result = KeyLedger.verify([record1, record2], firstKey: firstID, accounts: ["askhub-test-account"])
        #expect(result.problem == nil)
        #expect(Set(result.keys.keys) == [firstID, secondID])
    }

    @Test func storedIntentsFollowVectors() throws {
        let ledger = try Vectors.load("key-ledger.json", as: File.self)
        let file = try Vectors.load("stored-intent.json", as: StoredIntentFile.self)
        #expect(!file.cases.isEmpty)
        for vector in file.cases {
            var publicKeys: [KeyID: Data] = [:]
            for name in vector.trustedKeys {
                let key = try #require(ledger.keys[name])
                publicKeys[try #require(KeyID(rawValue: key.keyId))] = try #require(Base64URL.decode(key.publicKeyDer))
            }
            let now = try Date(vector.now, strategy: .iso8601)
            let result: String
            do {
                _ = try IntentVerifier(publicKeys: publicKeys).verify(stored: vector.value, now: now)
                result = "valid"
            } catch {
                result = "\(error)"
            }
            #expect("\(vector.name): \(result)" == "\(vector.name): \(vector.result)")
        }
    }

    private static func privateKey(_ key: LedgerVectorKey?) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: #require(key.flatMap { Base64URL.decode($0.privateKeyRaw) }))
    }

    /// 例の problem（`{"type": "…", "seq": n}` など）を、型の値にする
    private static func problem(_ value: JSONValue?) -> KeyLedger.Problem? {
        guard let value, let type = value["type"]?.stringValue else { return nil }
        let seq = value["seq"]?.integerValue.map(Int.init)
        let withSeq: [String: (Int) -> KeyLedger.Problem] = [
            "duplicateSequence": KeyLedger.Problem.duplicateSequence,
            "keyIdMismatch": KeyLedger.Problem.keyIdMismatch,
            "unknownSigner": KeyLedger.Problem.unknownSigner,
            "badSignature": KeyLedger.Problem.badSignature,
            "brokenLink": KeyLedger.Problem.brokenLink,
            "alreadyRegistered": KeyLedger.Problem.alreadyRegistered,
            "notRegistered": KeyLedger.Problem.notRegistered,
            "lastKeyRevoked": KeyLedger.Problem.lastKeyRevoked,
            "untrustedAccount": KeyLedger.Problem.untrustedAccount
        ]
        if let make = withSeq[type], let seq { return make(seq) }
        switch type {
        case "malformed": return .malformed(seq: seq)
        case "firstKeyNotPinned": return .firstKeyNotPinned
        case "outOfSequence":
            let found = value["found"]?.integerValue.map(Int.init)
            return value["expected"]?.integerValue.map { .outOfSequence(expected: Int($0), found: found) }
        default: return nil
        }
    }
}
