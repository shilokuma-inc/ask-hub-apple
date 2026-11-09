@testable import AskHubKeychain
import AskHubProtocol
import CryptoKit
import Foundation
import Testing

struct DeviceSigningKeyTests {
    private static let envelope = JSONValue.object(["v": .integer(1), "kind": .string("answer")])

    @Test func createsSoftwareKeyOnceAndSigns() throws {
        let store = InMemorySecretStore()
        let key = try DeviceSigningKey.loadOrCreate(in: store, useSecureEnclave: false)
        #expect(key.storage == .software)
        let again = try DeviceSigningKey.loadOrCreate(in: store, useSecureEnclave: false)
        #expect(again.keyID == key.keyID)
        let signature = try key.sign(Self.envelope)
        #expect(try IntentSignature.isValid(signature: signature, envelope: Self.envelope, publicKeyDER: key.publicKeyDER))
    }

    @Test func signsKeyRecordsThatVerify() throws {
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let record = KeyLedger.Record(
            seq: 1,
            action: .add,
            keyId: key.keyID,
            publicKey: Base64URL.encode(key.publicKeyDER),
            account: "askhub-test-account",
            label: "Mac",
            issuedAt: Timestamp(Date(timeIntervalSince1970: 1_793_700_000)),
            signedBy: key.keyID
        )
        let result = try KeyLedger.verify([key.sign(record)], firstKey: key.keyID, accounts: ["askhub-test-account"])
        #expect(result.problem == nil)
        #expect(Set(result.keys.keys) == [key.keyID])
    }

    @Test func rejectsUnreadableStoredKey() throws {
        let store = InMemorySecretStore([.signingKey: Data("not a key".utf8)])
        #expect(throws: DeviceSigningKey.Failure.unreadableKey) { try DeviceSigningKey.loadOrCreate(in: store, useSecureEnclave: false) }
        // 読めない鍵を、黙って作り直して上書きしない
        #expect(try store.read(.signingKey) == Data("not a key".utf8))
    }

    @Test(.enabled(if: SecureEnclave.isAvailable))
    func usesSecureEnclaveWhenAvailable() throws {
        let store = InMemorySecretStore()
        let key = try DeviceSigningKey.loadOrCreate(in: store)
        #expect(key.storage == .secureEnclave)
        let again = try DeviceSigningKey.loadOrCreate(in: store)
        #expect(again.keyID == key.keyID)
        let signature = try again.sign(Self.envelope)
        #expect(try IntentSignature.isValid(signature: signature, envelope: Self.envelope, publicKeyDER: key.publicKeyDER))
    }
}
