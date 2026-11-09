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
        return Self.registerCommand(publicKey: key.publicKey, account: account, label: Self.defaultDeviceLabel)
    }

    /// 端末の名前を、ターミナルにそのまま貼れるよう単一引用符で囲んで `--label` に渡す
    static func registerCommand(publicKey: String, account: String, label: String) -> String {
        "askhub key add --public-key \(publicKey) --account \(account) --label \(shellQuoted(label))"
    }

    /// 公開鍵の記録が受け付けるラベルの長さ（`KeyLedger` の 1〜64 文字）
    nonisolated static let maxDeviceLabelLength = 64

    /// 名前を入れていないときの端末の名前。Mac は複数台を見分けられるよう、コンピュータ名（システム設定の「共有」）を使う
    static let defaultDeviceLabel: String = {
        #if os(iOS)
        UIDevice.current.model
        #else
        Host.current().localizedName.flatMap(normalizedLabel) ?? "Mac"
        #endif
    }()

    /// 空白・改行を 1 つの空白にまとめ、長すぎれば切り詰める。何も残らなければ nil
    nonisolated private static func normalizedLabel(_ name: String) -> String? {
        let collapsed = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let label = String(collapsed.prefix(maxDeviceLabelLength)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// シェルの単一引用符で囲む。中の `'` は `'\''`（引用を閉じて、エスケープした `'` を置き、開き直す）にする
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\''") + "'"
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
