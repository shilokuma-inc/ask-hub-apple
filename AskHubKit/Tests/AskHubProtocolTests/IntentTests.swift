@testable import AskHubProtocol
import CryptoKit
import Foundation
import Testing

private struct IntentVectorKey: Decodable {
    let privateKeyRaw: String
    let publicKeyDer: String
    let keyId: String
}

private struct IntentVectorCase: Decodable {
    let name: String
    let text: String
    let trustedKeys: [String]
    let now: String
    let result: String
}

private struct IntentVectorFile: Decodable {
    let keys: [String: IntentVectorKey]
    let body: String
    let bodySha256: String
    let envelope: JSONValue
    let canonical: String
    let signature: String
    let cases: [IntentVectorCase]
}

struct IntentTests {
    private typealias File = IntentVectorFile

    @Test func keyIDsMatchVectors() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        for (name, key) in file.keys {
            let der = try #require(Base64URL.decode(key.publicKeyDer))
            #expect(IntentSignature.keyID(publicKeyDER: der) == key.keyId, "\(name)")
            // 秘密鍵から作った公開鍵も、例の公開鍵と同じになる
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: #require(Base64URL.decode(key.privateKeyRaw)))
            #expect(privateKey.publicKey.derRepresentation == der, "\(name)")
        }
    }

    @Test func envelopeCanonicalizesToVector() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        #expect(CanonicalJSON.string(for: file.envelope) == file.canonical)
        #expect(ProtocolMarker.bodySHA256(file.body) == file.bodySha256)
    }

    @Test func verifiesVectorSignature() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        let key1 = try #require(file.keys["key1"].flatMap { Base64URL.decode($0.publicKeyDer) })
        let key2 = try #require(file.keys["key2"].flatMap { Base64URL.decode($0.publicKeyDer) })
        #expect(try IntentSignature.isValid(signature: file.signature, envelope: file.envelope, publicKeyDER: key1))
        #expect(try !IntentSignature.isValid(signature: file.signature, envelope: file.envelope, publicKeyDER: key2))
    }

    @Test func signsAndVerifiesRoundTrip() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        let key = try #require(file.keys["key1"])
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: #require(Base64URL.decode(key.privateKeyRaw)))
        let signature = try IntentSignature.sign(envelope: file.envelope, with: privateKey)
        #expect(Base64URL.decode(signature)?.count == 64)
        let publicKey = privateKey.publicKey.derRepresentation
        #expect(try IntentSignature.isValid(signature: signature, envelope: file.envelope, publicKeyDER: publicKey))
    }

    @Test func rejectsMalformedSignature() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        let key1 = try #require(file.keys["key1"].flatMap { Base64URL.decode($0.publicKeyDer) })
        #expect(throws: IntentSignature.Failure.malformedSignature) {
            try IntentSignature.isValid(signature: "not base64url!", envelope: file.envelope, publicKeyDER: key1)
        }
        #expect(throws: IntentSignature.Failure.malformedSignature) {
            let shortSignature = Base64URL.encode(Data(repeating: 1, count: 63))
            return try IntentSignature.isValid(signature: shortSignature, envelope: file.envelope, publicKeyDER: key1)
        }
    }

    @Test func verifierFollowsVectorCases() throws {
        let file = try Vectors.load("intent-signature.json", as: File.self)
        #expect(!file.cases.isEmpty)
        for vector in file.cases {
            var publicKeys: [String: Data] = [:]
            for name in vector.trustedKeys {
                let key = try #require(file.keys[name])
                publicKeys[key.keyId] = try #require(Base64URL.decode(key.publicKeyDer))
            }
            let now = try Date(vector.now, strategy: .iso8601)
            #expect("\(vector.name): \(result(of: vector.text, publicKeys: publicKeys, now: now))" == "\(vector.name): \(vector.result)")
        }
    }

    @Test func base64URLRoundTrip() {
        for count in 0..<8 {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 77 &+ 250) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"))
            #expect(Base64URL.decode(encoded) == data)
        }
        #expect(Base64URL.decode("a") == nil)
        #expect(Base64URL.decode("ab+c") == nil)
    }

    private func result(of text: String, publicKeys: [String: Data], now: Date) -> String {
        guard let marker = ProtocolMarker.parse(text) else { return "noMarker" }
        do {
            _ = try IntentVerifier(publicKeys: publicKeys).verify(marker, now: now)
            return "valid"
        } catch {
            return "\(error)"
        }
    }
}
