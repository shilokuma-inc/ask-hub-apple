@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

/// 管理用のトークン（`docs/renewal/security.md` の「管理用のトークン」）: 毎日のトークンと混ざらず、自己診断に期限を書き、無ければ断る理由を出す
struct AdminTokenTests {
    static let now = TokenExpiryTests.now
    static let daily = "github_pat_" + String(repeating: "d", count: 40)
    static let admin = "github_pat_" + String(repeating: "a", count: 40)

    @Test func adminTokensAreKeptApartFromDailyTokens() throws {
        let secrets = InMemorySecretStore()
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "Shilokuma-Inc")
        // 別の名前で置き、毎日のトークンとしては読めない
        #expect(try secrets.read(SecretItem(rawValue: "github-admin-token/shilokuma-inc")) == Data(Self.admin.utf8))
        #expect(try GitHubTokens(secrets: secrets).token(for: "shilokuma-inc") == nil)
        #expect(try GitHubAdminTokens(secrets: secrets).token(for: "SHILOKUMA-INC") == Self.admin)
        #expect(try GitHubAdminTokens(secrets: secrets).state(of: "mrs1669") == .missing)
        try secrets.write(Data("ghp_classic".utf8), for: SecretItem(rawValue: "github-admin-token/mrs1669"))
        #expect(try GitHubAdminTokens(secrets: secrets).state(of: "mrs1669") == .invalid)
        #expect(throws: SecretStoreError.invalidOwner("a/b")) { try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "a/b") }
    }

    /// git の credential helper は毎日のトークンだけを返す（管理用のトークンしか無い持ち主には何も返さない）
    @Test func gitCredentialNeverReturnsAdminToken() throws {
        let secrets = InMemorySecretStore()
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "shilokuma-inc")
        let request = "protocol=https\nhost=github.com\npath=shilokuma-inc/ask-hub-apple.git\n"
        #expect(throws: GitCredential.Problem.missingToken(owner: "shilokuma-inc")) {
            try GitCredential.response(to: request, operation: "get", tokens: GitHubTokens(secrets: secrets))
        }
        try GitHubTokens(secrets: secrets).store(Self.daily, for: "shilokuma-inc")
        let response = try GitCredential.response(to: request, operation: "get", tokens: GitHubTokens(secrets: secrets))
        #expect(response.contains(Self.daily))
        #expect(!response.contains(Self.admin))
    }

    /// 自己診断は、管理用のトークンの様子と期限を別に書き、毎日のトークンのまとめ（githubToken）と上限の残りには入れない
    @Test func selfCheckWritesAdminTokensSeparately() async throws {
        let secrets = InMemorySecretStore([.claudeToken: Data("sk-ant-oat01-x".utf8)])
        try GitHubTokens(secrets: secrets).store(Self.daily, for: "shilokuma-inc")
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "shilokuma-inc")
        let daily = StubTransport([.json(200, TokenExpiryTests.rateLimitBody(remaining: 4_000))])
        let expiration = ["GitHub-Authentication-Token-Expiration": "2026-11-20 00:00:00 UTC"]
        let admin = StubTransport([.json(200, TokenExpiryTests.rateLimitBody(remaining: 3_990), headers: expiration)])
        let probe = MachineProbe(
            secrets: secrets,
            volume: FileManager.default.temporaryDirectory,
            owners: { ["shilokuma-inc"] },
            githubExpiry: GitHubTokenExpiry(transport: daily),
            adminOwners: { ["shilokuma-inc", "mrs1669"] },
            adminExpiry: GitHubTokenExpiry(transport: admin),
            now: { Self.now }
        )
        let check = await probe.selfCheck()
        #expect(check.githubAdminTokens == [
            .init(owner: "shilokuma-inc", state: .ok, expiresAt: Timestamp(rawValue: "2026-11-20T00:00:00Z")),
            .init(owner: "mrs1669", state: .missing)
        ])
        // 管理用のトークンが無い持ち主があっても、毎日の仕事のまとめは ok のまま。期限も毎日のトークンのものだけ
        #expect(check.githubToken == .ok)
        #expect(check.githubTokenExpiresAt == nil)
        #expect(check.githubRateLimit?.remaining == 4_000)
        // 管理用のトークンは、管理用の問い合わせにだけ使い、値は自己診断に入らない
        #expect(admin.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer \(Self.admin)"])
        #expect(daily.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer \(Self.daily)"])
        let encoded = try JSONEncoder().encode(check)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("github_pat_") == false)
    }

    /// 上限の残りだけを見る（1 分ごと）ときは、管理用のトークンを問い合わせない。置いた持ち主が無ければ自己診断に書かない
    @Test func rateLimitCheckSkipsAdminTokens() async throws {
        let secrets = InMemorySecretStore([.claudeToken: Data("sk-ant-oat01-x".utf8)])
        try GitHubTokens(secrets: secrets).store(Self.daily, for: "shilokuma-inc")
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "shilokuma-inc")
        let admin = StubTransport([])
        let probe = MachineProbe(
            secrets: secrets,
            volume: FileManager.default.temporaryDirectory,
            owners: { ["shilokuma-inc"] },
            githubExpiry: GitHubTokenExpiry(transport: StubTransport([.json(200, TokenExpiryTests.rateLimitBody(remaining: 4_000))])),
            adminOwners: { ["shilokuma-inc"] },
            adminExpiry: GitHubTokenExpiry(transport: admin),
            now: { Self.now }
        )
        #expect(await probe.githubRateLimit()?.remaining == 4_000)
        #expect(admin.requests.isEmpty)
        let worker = MachineProbe(
            secrets: secrets, volume: FileManager.default.temporaryDirectory, owners: { ["shilokuma-inc"] }, now: { Self.now }
        )
        #expect(await worker.selfCheck().githubAdminTokens == nil)
    }

    /// `admin-token <持ち主>` で足した持ち主は、設定の adminOwners に書き、常駐を読み込み直さなくても次の自己診断に出る。setup を流し直しても残る
    @Test func adminOwnersAreReloadedAndPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdminTokenTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let started = try MachineSetup.parse([
            "--state-repo", "shilokuma-inc/askhub-state", "--mac", "mac-mini", "--claude", "/opt/claude",
            "--first-key", MachineSetupTests.keyID, "--key-account", "a"
        ], role: .commander).configuration
        #expect(started.adminTokenOwners.isEmpty)
        try started.save(to: url)
        let secrets = InMemorySecretStore()
        let probe = MachineProbe(
            secrets: secrets, volume: directory, owners: { [] }, adminOwners: started.adminOwnersReloading(from: url, role: .commander)
        )
        #expect(await probe.selfCheck().githubAdminTokens == nil)
        var added = try MachineConfiguration.load(from: url, role: .commander)
        let new = added.addAdminOwner("Shilokuma-Inc")
        let existing = added.addAdminOwner("shilokuma-inc")
        #expect(new && !existing)
        // 毎日のトークンの持ち主には足さない
        #expect(added.tokenOwners == ["shilokuma-inc"])
        #expect(added.githubOwners.isEmpty)
        try added.save(to: url)
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "shilokuma-inc")
        #expect(await probe.selfCheck().githubAdminTokens == [.init(owner: "shilokuma-inc", state: .ok)])
        #expect(MachineConfiguration.preservedAdminOwners(at: url) == ["shilokuma-inc"])
        // 形の違う持ち主の名前は、設定として読まない
        var broken = added
        broken.adminOwners = ["a/b"]
        #expect(broken.problems.contains("adminOwners の a/b は GitHub の持ち主の名前の形でない"))
    }

    /// 無い・読めない持ち主の管理の操作は、入れ方を添えた理由で断る（トークンの値は含めない）
    @Test func missingAdminTokenGivesReason() throws {
        let secrets = InMemorySecretStore()
        try GitHubAdminTokens(secrets: secrets).store(Self.admin, for: "shilokuma-inc")
        let tokens = AdminTokens(secrets: secrets)
        #expect(tokens.token(for: "shilokuma-inc") == .success(Self.admin))
        #expect(tokens.token(for: "mrs1669") == .failure(.missing(owner: "mrs1669")))
        #expect(AdminTokenProblem.missing(owner: "mrs1669").description
            == "mrs1669 の管理用のトークンが無い（常時オンの Mac で askhub-commander admin-token mrs1669 を流して入れる）")
        struct Denied: Error {}
        #expect(AdminTokens { _ in throw Denied() }.token(for: "mrs1669") == .failure(.unreadable(owner: "mrs1669")))
        #expect(AdminTokens { _ in "" }.token(for: "mrs1669") == .failure(.missing(owner: "mrs1669")))
    }
}
