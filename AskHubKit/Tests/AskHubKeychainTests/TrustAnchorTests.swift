@testable import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

struct TrustAnchorTests {
    private func anchor(pinned: Bool = true) throws -> (TrustAnchor, Vectors.Ledger) {
        let ledger = try Vectors.ledger()
        let anchor = TrustAnchor(store: InMemorySecretStore())
        if pinned { try anchor.pin(firstKey: ledger.key("key1")) }
        return (anchor, ledger)
    }

    @Test func pinsFirstKeyOnce() throws {
        let (anchor, ledger) = try anchor(pinned: false)
        #expect(try anchor.firstKey() == nil)
        try anchor.pin(firstKey: ledger.key("key1"))
        try anchor.pin(firstKey: ledger.key("key1"))
        #expect(throws: TrustAnchor.Failure.pinnedToAnotherKey) { try anchor.pin(firstKey: ledger.key("key2")) }
        #expect(try anchor.firstKey() == ledger.key("key1"))
    }

    @Test func refusesToRefreshWithoutPin() throws {
        let (anchor, ledger) = try anchor(pinned: false)
        #expect(throws: TrustAnchor.Failure.notPinned) {
            try anchor.refresh(records: ledger.records("valid-chain"), accounts: Set(ledger.accounts))
        }
    }

    @Test func refreshesAndExtends() throws {
        let (anchor, ledger) = try anchor()
        let chain = ledger.records("valid-chain")
        let accounts = Set(ledger.accounts)
        #expect(try anchor.refresh(records: Array(chain.prefix(1)), accounts: accounts) == .updated(added: 1))
        #expect(try Set(anchor.trustedKeys().keys) == [ledger.key("key1")])
        #expect(try anchor.refresh(records: chain, accounts: accounts) == .updated(added: 2))
        #expect(try Set(anchor.trustedKeys().keys) == [ledger.key("key2")])
        #expect(try anchor.refresh(records: chain, accounts: accounts) == .updated(added: 0))
    }

    /// 取り消しの記録を消して、取り消した鍵を戻そうとしても、一覧を変えない
    @Test func refusesShorterChain() throws {
        let (anchor, ledger) = try anchor()
        let chain = ledger.records("valid-chain")
        let accounts = Set(ledger.accounts)
        _ = try anchor.refresh(records: chain, accounts: accounts)
        #expect(try anchor.refresh(records: Array(chain.prefix(2)), accounts: accounts) == .rollback)
        #expect(try Set(anchor.trustedKeys().keys) == [ledger.key("key2")])
    }

    /// 前に確かめた記録が、別の正しく署名された記録に差し替えられたときも、一覧を変えない
    @Test func refusesDivergingChain() throws {
        let (anchor, ledger) = try anchor()
        let accounts = Set(ledger.accounts)
        // revoked-signer の 3 つ目は「key2 の取り消し」で、valid-chain の 3 つ目（key1 の取り消し）と違う
        _ = try anchor.refresh(records: ledger.records("valid-chain"), accounts: accounts)
        #expect(try anchor.refresh(records: Array(ledger.records("revoked-signer").prefix(3)), accounts: accounts) == .rollback)
        #expect(try Set(anchor.trustedKeys().keys) == [ledger.key("key2")])
    }

    @Test func keepsVerifiedPrefixWhenLaterRecordIsBad() throws {
        let (anchor, ledger) = try anchor()
        let result = try anchor.refresh(records: ledger.records("revoked-signer"), accounts: Set(ledger.accounts))
        #expect(result == .problem(.unknownSigner(seq: 4), added: 3))
        #expect(try Set(anchor.trustedKeys().keys) == [ledger.key("key1")])
    }

    @Test func providesPublicKeysForVerifier() throws {
        let (anchor, ledger) = try anchor()
        _ = try anchor.refresh(records: ledger.records("valid-chain"), accounts: Set(ledger.accounts))
        let key = try #require(anchor.trustedKeys()[ledger.key("key2")])
        #expect(IntentSignature.keyID(publicKeyDER: key.publicKeyDER) == ledger.key("key2"))
        #expect(key.account == "askhub-test-account")
    }
}
