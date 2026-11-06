import AskHubKeychain
import AskHubProtocol
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 設定の「状態リポジトリ」の節の状態。
///
/// GitHub のトークンは Keychain にだけ書き、保存済みの値は画面に出さない（保存済みかどうかだけを持つ）
@Observable
final class ConnectionSettingsModel {
    struct DeviceKey: Equatable {
        var keyID: String
        /// SubjectPublicKeyInfo の DER を base64url にしたもの（`askhub key add --public-key` に渡す形）
        var publicKey: String
        var isSecureEnclave: Bool
    }

    /// 入力中のトークン
    var tokenInput = ""
    private(set) var hasToken = false
    private(set) var key: DeviceKey?
    private(set) var registration: KeyRegistration?
    private(set) var isCheckingRegistration = false
    private(set) var errorMessage: String?

    private let tokens: any SecretStore

    init(tokens: any SecretStore = StateConnection.tokenStore) {
        self.tokens = tokens
    }

    func load() async {
        hasToken = (try? tokens.read(.githubToken)) != nil
        do {
            let key = try StateConnection.deviceKey()
            self.key = DeviceKey(
                keyID: key.keyID.rawValue,
                publicKey: Base64URL.encode(key.publicKeyDER),
                isSecureEnclave: key.storage == .secureEnclave
            )
            await checkRegistration(of: key.keyID)
        } catch {
            errorMessage = "この端末の署名の鍵を用意できませんでした。端末のロックを解除してから開き直してください"
        }
    }

    /// 公開鍵の記録を読み直して、この端末の鍵が登録されたかを確かめる
    func checkRegistration() async {
        guard let keyID = key.flatMap({ KeyID(rawValue: $0.keyID) }) else {
            return
        }
        await checkRegistration(of: keyID)
    }

    private func checkRegistration(of keyID: KeyID) async {
        guard hasToken, let repository = StateConnection.repository() else {
            registration = nil
            return
        }
        isCheckingRegistration = true
        defer { isCheckingRegistration = false }
        registration = await KeyRegistration.read(from: StateConnection.makeStore(repository: repository, tokens: tokens), device: keyID)
    }

    var canSaveToken: Bool {
        !trimmedToken.isEmpty
    }

    func saveToken() async {
        do {
            try tokens.write(Data(trimmedToken.utf8), for: .githubToken)
            hasToken = true
            tokenInput = ""
            errorMessage = nil
            await checkRegistration()
        } catch {
            errorMessage = "トークンを Keychain に保存できませんでした"
        }
    }

    func deleteToken() {
        do {
            try tokens.delete(.githubToken)
            hasToken = false
            registration = nil
            errorMessage = nil
        } catch {
            errorMessage = "トークンを Keychain から消せませんでした"
        }
    }

    /// Mac の非常口のコマンドで、この端末の鍵を登録するときに貼るもの
    var registerCommand: String? {
        guard let key else {
            return nil
        }
        var account = "<GitHub のアカウント>"
        if case .notRegistered(let first?) = registration {
            account = first
        }
        return "askhub key add --public-key \(key.publicKey) --account \(account) --label \(Self.deviceLabel)"
    }

    /// 公開鍵の記録に付ける端末の名前
    static var deviceLabel: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
