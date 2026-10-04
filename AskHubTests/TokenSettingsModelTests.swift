@testable import AskHub
import AskHubKit
import Foundation
import Security
import Testing

@MainActor
struct TokenSettingsModelTests {
    @Test func loadReflectsSavedToken() {
        let model = TokenSettingsModel(store: InMemoryTokenStore(token: "github_pat_saved"))
        #expect(!model.hasSavedToken)
        model.load()
        #expect(model.hasSavedToken)
        #expect(model.input.isEmpty)
    }

    @Test func saveTrimsInputAndClearsField() throws {
        let store = InMemoryTokenStore()
        let model = TokenSettingsModel(store: store)
        model.input = "  github_pat_new \n"
        model.save()
        #expect(try store.load() == "github_pat_new")
        #expect(model.hasSavedToken)
        #expect(model.input.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func blankInputCannotBeSaved() throws {
        let store = InMemoryTokenStore()
        let model = TokenSettingsModel(store: store)
        model.input = "   "
        #expect(!model.canSave)
        model.save()
        #expect(try store.load() == nil)
        #expect(!model.hasSavedToken)
    }

    @Test func deleteRemovesToken() throws {
        let store = InMemoryTokenStore(token: "github_pat_saved")
        let model = TokenSettingsModel(store: store)
        model.load()
        model.delete()
        #expect(try store.load() == nil)
        #expect(!model.hasSavedToken)
    }

    @Test func keychainErrorIsShownWithoutToken() {
        let model = TokenSettingsModel(store: FailingTokenStore())
        model.input = "github_pat_secret"
        model.save()
        #expect(!model.hasSavedToken)
        let message = model.errorMessage ?? ""
        #expect(message.contains("\(errSecInteractionNotAllowed)"))
        #expect(!message.contains("github_pat_secret"))
        #expect(model.input == "github_pat_secret")
    }
}

/// 常に失敗する保存先
private struct FailingTokenStore: TokenStore {
    func load() throws -> String? {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }

    func save(_ token: String) throws {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }

    func delete() throws {
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
}
