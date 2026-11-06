@testable import AskHubKeychain
import Foundation
import Testing

struct KeychainSecretStoreTests {
    @Test func inMemoryStoreReadsWritesAndDeletes() throws {
        let store = InMemorySecretStore()
        #expect(try store.read(.githubToken) == nil)
        try store.write(Data("a".utf8), for: .githubToken)
        try store.write(Data("b".utf8), for: .githubToken)
        #expect(try store.read(.githubToken) == Data("b".utf8))
        try store.delete(.githubToken)
        try store.delete(.githubToken)
        #expect(try store.read(.githubToken) == nil)
    }

    /// 本物の Keychain で確かめる。ふだん（CI を含む）は流さない。
    /// `ASKHUB_LIVE_KEYCHAIN_TEST=1 swift test --package-path AskHubKit --filter KeychainSecretStoreTests` で流す。
    /// ログインの Keychain に、テスト専用の service の項目を作り、終わったら消す
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ASKHUB_LIVE_KEYCHAIN_TEST"] == "1"))
    func liveKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "jp.shilokuma.askhub.test.\(UUID().uuidString)")
        defer {
            for item in SecretItem.allCases {
                try? store.delete(item)
            }
        }
        for item in SecretItem.allCases {
            #expect(try store.read(item) == nil)
            try store.write(Data("1-\(item.rawValue)".utf8), for: item)
            try store.write(Data("2-\(item.rawValue)".utf8), for: item)
            #expect(try store.read(item) == Data("2-\(item.rawValue)".utf8))
        }
        try store.delete(.githubToken)
        #expect(try store.read(.githubToken) == nil)
        #expect(try store.read(.claudeToken) == Data("2-claude-token".utf8))
    }
}
