@testable import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

struct GitHubTokensTests {
    @Test func tokensAreKeptPerOwnerIgnoringCase() throws {
        let secrets = InMemorySecretStore()
        let tokens = GitHubTokens(secrets: secrets)
        try tokens.store("github_pat_shilokuma", for: "Shilokuma-Inc")
        try tokens.store("github_pat_personal", for: "mrs1669")
        #expect(try tokens.token(for: "shilokuma-inc") == "github_pat_shilokuma")
        #expect(try tokens.token(for: "MRS1669") == "github_pat_personal")
        #expect(try tokens.token(for: "yumemi") == nil)
        // 持ち主ごとの名前で置き、クライアントの 1 つのトークンとは分ける
        #expect(try secrets.read(SecretItem(rawValue: "github-token/shilokuma-inc")) == Data("github_pat_shilokuma".utf8))
        #expect(try secrets.read(.githubToken) == nil)
    }

    @Test func refusesNamesThatAreNotOwners() throws {
        let tokens = GitHubTokens(secrets: InMemorySecretStore())
        for owner in ["", "-a", "a/b", "a b", "..", String(repeating: "a", count: 40), "ａ"] {
            #expect(GitHubTokens.normalizedOwner(owner) == nil)
            #expect(throws: SecretStoreError.invalidOwner(owner)) { try tokens.store("github_pat_x", for: owner) }
            #expect(try tokens.token(for: owner) == nil)
        }
        #expect(GitHubTokens.normalizedOwner("Shilokuma-Inc") == "shilokuma-inc")
    }

    @Test func acceptsOnlyFineGrainedTokens() {
        #expect(GitHubTokens.problem(of: "github_pat_11ABCDEFG_abc") == nil)
        #expect(GitHubTokens.problem(of: "ghp_abc")?.contains("classic") == true)
        #expect(GitHubTokens.problem(of: "github_pat_") != nil)
        #expect(GitHubTokens.problem(of: "sk-ant-oat01-x") != nil)
        #expect(GitHubTokens.problem(of: "github_pat_a b") != nil)
    }

    @Test func selfCheckLooksAtEveryOwnerWithoutValues() throws {
        let secrets = InMemorySecretStore()
        let tokens = GitHubTokens(secrets: secrets)
        #expect(try tokens.state(of: ["shilokuma-inc"]) == .missing)
        try tokens.store("github_pat_a", for: "shilokuma-inc")
        #expect(try tokens.state(of: ["shilokuma-inc"]) == .ok)
        try secrets.write(Data("ghp_old".utf8), for: SecretItem(rawValue: "github-token/mrs1669"))
        #expect(try tokens.state(of: ["shilokuma-inc", "mrs1669"]) == .invalid)
        #expect(try tokens.state(of: ["shilokuma-inc", "mrs1669", "yumemi"]) == .missing)
    }
}
