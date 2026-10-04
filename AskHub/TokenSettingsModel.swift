import AskHubKit
import Foundation
import Observation

/// 設定画面で GitHub のトークンを入力・保存・削除するための状態。
///
/// 保存済みのトークンの値は画面に出さず、保存済みかどうかだけを持つ。
@MainActor
@Observable
final class TokenSettingsModel {
    /// 入力中のトークン
    var input = ""
    /// トークンを保存済みか
    private(set) var hasSavedToken = false
    /// 直前の操作で起きたエラー
    private(set) var errorMessage: String?

    private let store: any TokenStore

    init(store: any TokenStore = KeychainTokenStore.gitHub) {
        self.store = store
    }

    /// 保存できる入力か（前後の空白を除いて空でない）
    var canSave: Bool {
        !trimmedInput.isEmpty
    }

    /// 保存済みかを読み直す
    func load() {
        do {
            hasSavedToken = try store.load() != nil
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error, action: "読み込め")
        }
    }

    /// 入力したトークンを保存し、入力欄を空にする
    func save() {
        guard canSave else {
            return
        }
        do {
            try store.save(trimmedInput)
            input = ""
            hasSavedToken = true
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error, action: "保存でき")
        }
    }

    /// 保存済みのトークンを削除する
    func delete() {
        do {
            try store.delete()
            hasSavedToken = false
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error, action: "削除でき")
        }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// エラーの説明。トークンの値は含めない
    private static func message(for error: any Error, action: String) -> String {
        if let error = error as? KeychainError {
            return "Keychain に\(action)ませんでした（OSStatus \(error.status)）"
        }
        return "Keychain に\(action)ませんでした"
    }
}
