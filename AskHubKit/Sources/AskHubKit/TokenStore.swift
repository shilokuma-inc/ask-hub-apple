import Foundation
import os
import Security

/// GitHub のトークンの保存先。
///
/// トークンは Keychain 以外（UserDefaults・ログ・URL など）に書かない。
/// テストではメモリ上の実装に差し替える。
public protocol TokenStore: Sendable {
    /// 保存済みのトークン。無ければ `nil`
    func load() throws -> String?
    /// トークンを保存する（既にあれば上書きする）
    func save(_ token: String) throws
    /// 保存済みのトークンを削除する。無くてもエラーにしない
    func delete() throws
}

/// Keychain の操作に失敗したときのエラー。トークンの値は含めない
public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

/// Keychain（generic password）にトークンを保存する `TokenStore`
public struct KeychainTokenStore: TokenStore {
    /// 既定の保存先（GitHub の Fine-grained PAT）
    public static let gitHub = Self(service: "jp.shilokuma.AskHub.github", account: "personal-access-token")

    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)

        case errSecItemNotFound:
            return nil

        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return

        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            // 端末のロックを解除した後なら、バックグラウンドの更新でも読めるようにする。他の端末には同期しない
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus)
            }

        default:
            throw KeychainError(status: updateStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// メモリ上にトークンを持つ `TokenStore`。テストとプレビュー用
public final class InMemoryTokenStore: TokenStore {
    private let token: OSAllocatedUnfairLock<String?>

    public init(token: String? = nil) {
        self.token = OSAllocatedUnfairLock(initialState: token)
    }

    public func load() throws -> String? {
        token.withLock { $0 }
    }

    public func save(_ token: String) throws {
        self.token.withLock { $0 = token }
    }

    public func delete() throws {
        token.withLock { $0 = nil }
    }
}
