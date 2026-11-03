import Foundation
import os
import Security

/// Keychain に置くもの（`docs/renewal/security.md` の「秘密の置き場所」）。秘密はここ以外（ファイル・環境変数・ログ・URL）に置かない
public enum SecretItem: String, CaseIterable, Sendable {
    /// GitHub のトークン（ワーカー・司令塔・クライアント）
    case githubToken = "github-token"
    /// Claude の setup-token（ワーカー・司令塔）
    case claudeToken = "claude-token"
    /// APNs の鍵（司令塔）
    case apnsKey = "apns-key"
    /// 人の意図に署名する鍵（クライアント・非常口）。Secure Enclave の鍵なら、その端末でしか使えない形
    case signingKey = "signing-key"
    /// セットアップで固定した最初の鍵の id（ワーカー・司令塔）
    case firstKeyID = "first-key-id"
    /// 確かめた公開鍵の一覧（ワーカー・司令塔）
    case trustedKeys = "trusted-keys"
}

/// Keychain の操作の失敗。秘密の値は含めない
public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(status: OSStatus)
    /// 保存されている値の形が違う
    case malformed(SecretItem)
}

/// 秘密の置き場所。テストではメモリーの実装に差し替える
public protocol SecretStore: Sendable {
    /// 無ければ nil
    func read(_ item: SecretItem) throws(SecretStoreError) -> Data?
    /// 書く（すでにあれば置き換える）
    func write(_ data: Data, for item: SecretItem) throws(SecretStoreError)
    /// 消す。無くても失敗にしない
    func delete(_ item: SecretItem) throws(SecretStoreError)
}

/// Keychain（generic password）に置く `SecretStore`。
///
/// macOS では `kSecUseDataProtectionKeychain` を付けず、従来の Keychain を使う（provisioning profile の entitlement の無い
/// ワーカーと司令塔でも使えるように。`LEARNINGS.md`）。従来の Keychain では、項目を作ったプログラムだけが確認なしで読め、
/// ほかのプログラムが読もうとすると確認の画面が出る（画面の無い実行では失敗する）。そのため `kSecAttrAccessible` は iOS でだけ効く
public struct KeychainSecretStore: SecretStore {
    /// 項目の service（例: `jp.shilokuma.askhub.worker`）。役割ごとに分ける
    public let service: String
    /// iOS で読める条件。どちらも、ほかの端末に同期しない
    public enum Accessibility: Sendable {
        /// 起動後に一度ロックを解除すれば、裏の処理でも読める
        case afterFirstUnlock
        /// ロック解除中だけ読める
        case whenUnlocked

        var value: CFString {
            switch self {
            case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlocked: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    public let accessibility: Accessibility

    public init(service: String, accessibility: Accessibility = .afterFirstUnlock) {
        self.service = service
        self.accessibility = accessibility
    }

    public func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .malformed(item) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status: status)
        }
    }

    public func write(_ data: Data, for item: SecretItem) throws(SecretStoreError) {
        let updateStatus = SecItemUpdate(baseQuery(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(item)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = accessibility.value
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw .keychain(status: addStatus) }
        default:
            throw .keychain(status: updateStatus)
        }
    }

    public func delete(_ item: SecretItem) throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status: status) }
    }

    private func baseQuery(_ item: SecretItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
    }
}

/// メモリーに置く `SecretStore`。テストとプレビュー用
public final class InMemorySecretStore: SecretStore {
    private let items = OSAllocatedUnfairLock<[SecretItem: Data]>(initialState: [:])

    public init(_ items: [SecretItem: Data] = [:]) {
        self.items.withLock { $0 = items }
    }

    public func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
        items.withLock { $0[item] }
    }

    public func write(_ data: Data, for item: SecretItem) throws(SecretStoreError) {
        items.withLock { $0[item] = data }
    }

    public func delete(_ item: SecretItem) throws(SecretStoreError) {
        _ = items.withLock { $0.removeValue(forKey: item) }
    }
}
