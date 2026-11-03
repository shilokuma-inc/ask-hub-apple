import AskHubProtocol
import CryptoKit
import Foundation
import Security

/// 人の意図に署名する、端末ごとの鍵（`docs/renewal/security.md` の「鍵」）。
///
/// - Secure Enclave が使えれば、そこに作る。鍵はその端末の外に出ず、Keychain にはその端末でしか使えない形だけを置く
/// - 使える条件は「端末のロックが解除されている間」。Face ID・Touch ID は求めない（Siri やショートカットからも署名できるように。ユーザーの決定）
/// - Secure Enclave の無い環境（Simulator など）では、ソフトウェアの鍵にする。`storage` で見分け、登録の画面に出す
public struct DeviceSigningKey: Sendable {
    public enum Storage: String, Codable, Sendable {
        case secureEnclave
        case software
    }

    public enum Failure: Error, Equatable, Sendable {
        case store(SecretStoreError)
        /// 保存されている鍵を読めない（別の端末の Secure Enclave の鍵など）
        case unreadableKey
        case signingFailed
    }

    public let storage: Storage
    public let publicKeyDER: Data
    public var keyID: KeyID { IntentSignature.keyID(publicKeyDER: publicKeyDER) }

    private let key: Key

    private enum Key: Sendable {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    /// Keychain に置く形
    private struct Stored: Codable {
        let storage: Storage
        /// Secure Enclave の鍵は `dataRepresentation`（その端末でしか使えない）、ソフトウェアの鍵は生の値
        let key: Data
    }

    /// 保存済みの鍵を読む。無ければ作って保存する
    public static func loadOrCreate(in store: any SecretStore, useSecureEnclave: Bool = SecureEnclave.isAvailable) throws(Failure) -> Self {
        let data: Data?
        do {
            data = try store.read(.signingKey)
        } catch {
            throw .store(error)
        }
        if let data { return try load(data) }
        let created = try create(useSecureEnclave: useSecureEnclave)
        let stored = try created.stored()
        do {
            try store.write(stored, for: .signingKey)
        } catch {
            throw .store(error)
        }
        return created
    }

    /// 封筒・公開鍵の記録に署名する（`IntentSignature` と同じ方式）
    public func sign(_ value: JSONValue) throws(Failure) -> String {
        do {
            switch key {
            case let .secureEnclave(privateKey):
                return try IntentSignature.sign(envelope: value) { try privateKey.signature(for: $0) }
            case let .software(privateKey):
                return try IntentSignature.sign(envelope: value, with: privateKey)
            }
        } catch {
            throw .signingFailed
        }
    }

    /// 公開鍵の記録に署名する
    public func sign(_ record: KeyLedger.Record) throws(Failure) -> JSONValue {
        do {
            switch key {
            case let .secureEnclave(privateKey):
                return try KeyLedger.sign(record) { try privateKey.signature(for: $0) }
            case let .software(privateKey):
                return try KeyLedger.sign(record) { try privateKey.signature(for: $0) }
            }
        } catch {
            throw .signingFailed
        }
    }

    // MARK: -

    private static func create(useSecureEnclave: Bool) throws(Failure) -> Self {
        guard useSecureEnclave else {
            let privateKey = P256.Signing.PrivateKey()
            return Self(storage: .software, publicKeyDER: privateKey.publicKey.derRepresentation, key: .software(privateKey))
        }
        var error: Unmanaged<CFError>?
        // ロック解除中だけ・この端末だけで使える。生体認証は求めない
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error),
              let privateKey = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
            error?.release()
            throw .signingFailed
        }
        return Self(storage: .secureEnclave, publicKeyDER: privateKey.publicKey.derRepresentation, key: .secureEnclave(privateKey))
    }

    private static func load(_ data: Data) throws(Failure) -> Self {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { throw .unreadableKey }
        switch stored.storage {
        case .secureEnclave:
            guard let privateKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key) else { throw .unreadableKey }
            return Self(storage: .secureEnclave, publicKeyDER: privateKey.publicKey.derRepresentation, key: .secureEnclave(privateKey))
        case .software:
            guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: stored.key) else { throw .unreadableKey }
            return Self(storage: .software, publicKeyDER: privateKey.publicKey.derRepresentation, key: .software(privateKey))
        }
    }

    private init(storage: Storage, publicKeyDER: Data, key: Key) {
        self.storage = storage
        self.publicKeyDER = publicKeyDER
        self.key = key
    }

    private func stored() throws(Failure) -> Data {
        let raw: Data
        switch key {
        case let .secureEnclave(privateKey): raw = privateKey.dataRepresentation
        case let .software(privateKey): raw = privateKey.rawRepresentation
        }
        do {
            return try JSONEncoder().encode(Stored(storage: storage, key: raw))
        } catch {
            throw .unreadableKey
        }
    }
}
