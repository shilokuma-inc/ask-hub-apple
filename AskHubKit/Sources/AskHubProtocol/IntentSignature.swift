import CryptoKit
import Foundation

/// 人の意図の封筒の署名（`docs/renewal/protocol.md` の「署名のしかた」）。
///
/// - 方式は ECDSA P-256・SHA-256
/// - 署名するのは、封筒を `CanonicalJSON` でそろえた UTF-8 のバイト列
/// - 署名は IEEE P1363 の形（r と s を 32 バイトずつつないだ 64 バイト）を base64url にしたもの
/// - 鍵の id は、公開鍵（SubjectPublicKeyInfo の DER）の SHA-256 を base64url にしたもの
public enum IntentSignature {
    public enum Failure: Error, Equatable {
        case malformedSignature
        case malformedPublicKey
    }

    public static func keyID(publicKeyDER: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: publicKeyDER)))
    }

    /// 封筒に署名する。Secure Enclave の鍵でも使えるよう、署名そのものは呼び出し側に任せる
    public static func sign(
        envelope: JSONValue,
        using signer: (Data) throws -> P256.Signing.ECDSASignature
    ) rethrows -> String {
        let signature = try signer(CanonicalJSON.data(for: envelope))
        return Base64URL.encode(signature.rawRepresentation)
    }

    public static func sign(envelope: JSONValue, with key: P256.Signing.PrivateKey) throws -> String {
        try sign(envelope: envelope) { try key.signature(for: $0) }
    }

    /// 署名が、その公開鍵で封筒に対して正しいかを確かめる。形が壊れていれば投げ、合わなければ `false`
    public static func isValid(signature: String, envelope: JSONValue, publicKeyDER: Data) throws -> Bool {
        guard let raw = Base64URL.decode(signature), raw.count == 64,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            throw Failure.malformedSignature
        }
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyDER) else {
            throw Failure.malformedPublicKey
        }
        return publicKey.isValidSignature(ecdsa, for: CanonicalJSON.data(for: envelope))
    }
}

/// パディングの無い base64url（RFC 4648 の 5 節）
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// パディングの有無にかかわらず読む。base64url でない文字があれば `nil`
    public static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else {
            return nil
        }
        var base64 = text
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
