@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import Foundation
import Testing

/// トークンの期限（GitHub の応答の見出し・Claude の setup-token を入れた日）を、生きている印の自己診断に書く
struct TokenExpiryTests {
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let token = "github_pat_" + String(repeating: "a", count: 40)

    /// 期限の見出しつきの応答
    static func expiring(_ value: String, status: Int = 200) -> StubTransport.Reply {
        .json(status, "{}", headers: ["GitHub-Authentication-Token-Expiration": value])
    }

    @Test func parsesExpirationHeader() throws {
        let expected = try #require(Timestamp(rawValue: "2027-10-23T12:25:03Z")).date
        // GitHub が実際に返す形（2026-11 に確かめた）と、時差の形
        #expect(GitHubTokenExpiry.parse("2027-10-23 12:25:03 UTC") == expected)
        #expect(GitHubTokenExpiry.parse("2027-10-23 21:25:03 +0900") == expected)
        #expect(GitHubTokenExpiry.parse("2027-10-23T12:25:03Z") == expected)
        #expect(GitHubTokenExpiry.parse("") == nil)
        #expect(GitHubTokenExpiry.parse("next year") == nil)
    }

    @Test func readsExpirationFromRateLimitWithoutExposingToken() async throws {
        let transport = StubTransport([Self.expiring("2026-11-20 00:00:00 UTC")])
        let expiry = GitHubTokenExpiry(transport: transport)
        let checked = await expiry.check(owner: "shilokuma-inc", token: Self.token, now: Self.now)
        #expect(checked == .init(owner: "shilokuma-inc", state: .ok, expiresAt: Timestamp(rawValue: "2026-11-20T00:00:00Z")))
        // 上限に数えられない /rate_limit を呼び、トークンは Authorization にだけ入れる
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/rate_limit")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.url?.absoluteString.contains(Self.token) == false)
    }

    @Test func keepsLastExpirationWhenGitHubIsUnreachable() async throws {
        let expiresAt = Timestamp(rawValue: "2026-11-20T00:00:00Z")
        // 1 回目は読め、2 回目は GitHub の障害（見出しなし）、3 回目はつながらない
        let transport = StubTransport([Self.expiring("2026-11-20 00:00:00 UTC"), .json(503, "{}")])
        let expiry = GitHubTokenExpiry(transport: transport)
        _ = await expiry.check(owner: "a", token: Self.token, now: Self.now)
        #expect(await expiry.check(owner: "a", token: Self.token, now: Self.now) == .init(owner: "a", state: .ok, expiresAt: expiresAt))
        #expect(await expiry.check(owner: "a", token: Self.token, now: Self.now) == .init(owner: "a", state: .ok, expiresAt: expiresAt))
    }

    @Test func tokenWithoutExpirationHasNoDate() async {
        // 期限の無いトークンには見出しが無い。前に読んだ期限も消す（入れ直した）
        let transport = StubTransport([Self.expiring("2026-11-20 00:00:00 UTC"), .json(200, "{}")])
        let expiry = GitHubTokenExpiry(transport: transport)
        _ = await expiry.check(owner: "a", token: Self.token, now: Self.now)
        #expect(await expiry.check(owner: "a", token: Self.token, now: Self.now) == .init(owner: "a", state: .ok))
    }

    @Test func rejectedTokenIsExpiredOnlyAfterKnownExpiration() async {
        let later = Self.now.addingTimeInterval(30 * 24 * 60 * 60)
        let transport = StubTransport([Self.expiring("2026-11-20 00:00:00 UTC"), .json(401, "{}"), .json(401, "{}")])
        let expiry = GitHubTokenExpiry(transport: transport)
        _ = await expiry.check(owner: "a", token: Self.token, now: Self.now)
        // 期限の前に断られたら、取り消し・作り直しなので使えない
        #expect(await expiry.check(owner: "a", token: Self.token, now: Self.now).state == .invalid)
        // 期限を過ぎて断られたら、期限切れ（期限も残す）
        let expired = await expiry.check(owner: "a", token: Self.token, now: later)
        #expect(expired == .init(owner: "a", state: .expired, expiresAt: Timestamp(rawValue: "2026-11-20T00:00:00Z")))
        // 期限を知らないまま断られたら、使えない
        let unknown = GitHubTokenExpiry(transport: StubTransport([.json(401, "{}")]))
        #expect(await unknown.check(owner: "b", token: Self.token, now: Self.now) == .init(owner: "b", state: .invalid))
    }

    @Test func selfCheckWritesEarliestGitHubExpirationPerOwner() async throws {
        let secrets = InMemorySecretStore([.claudeToken: Data("sk-ant-oat01-x".utf8)])
        let tokens = GitHubTokens(secrets: secrets)
        for owner in ["shilokuma-inc", "mrs1669", "other"] {
            try tokens.store(Self.token, for: owner)
        }
        try tokens.store("ghp_classic", for: "other")
        // 形の合わないトークン（other）は問い合わせない
        let transport = StubTransport([Self.expiring("2027-01-01 00:00:00 UTC"), Self.expiring("2026-11-20 00:00:00 UTC")])
        let probe = MachineProbe(
            secrets: secrets,
            volume: FileManager.default.temporaryDirectory,
            owners: { ["shilokuma-inc", "mrs1669", "other"] },
            githubExpiry: GitHubTokenExpiry(transport: transport),
            now: { Self.now }
        )
        let check = await probe.selfCheck()
        #expect(transport.requests.count == 2)
        #expect(check.githubToken == .invalid)
        #expect(check.githubTokenExpiresAt == Timestamp(rawValue: "2026-11-20T00:00:00Z"))
        #expect(check.githubTokens == [
            .init(owner: "shilokuma-inc", state: .ok, expiresAt: Timestamp(rawValue: "2027-01-01T00:00:00Z")),
            .init(owner: "mrs1669", state: .ok, expiresAt: Timestamp(rawValue: "2026-11-20T00:00:00Z")),
            .init(owner: "other", state: .invalid)
        ])
        // 値そのものは自己診断に入らない
        let mac = try #require(MacName(rawValue: "mac-mini"))
        let file = MacFile(
            mac: mac,
            kind: .alwaysOn,
            seenAt: Timestamp(Self.now),
            versions: .init(worker: "1.0.0"),
            diskFreeGB: 1,
            load: 0,
            capacity: .init(claude: 1, build: 0),
            selfCheck: check
        )
        let encoded = try StateFileCoder.encode(file)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("github_pat_") == false)
    }

    @Test func summarizesOwnerStates() {
        #expect(MachineProbe.summary(of: [.ok, .ok]) == .ok)
        #expect(MachineProbe.summary(of: [.ok, .expired]) == .expired)
        #expect(MachineProbe.summary(of: [.expired, .invalid]) == .invalid)
        #expect(MachineProbe.summary(of: [.invalid, .missing, .expired]) == .missing)
    }

    // MARK: - Claude の setup-token

    @Test func claudeTokenExpiresOneYearAfterItWasStored() throws {
        let stored = try #require(Timestamp(rawValue: "2026-11-08T09:00:00Z"))
        #expect(ClaudeTokenRecord(storedAt: stored).expiresAt == Timestamp(rawValue: "2027-11-08T09:00:00Z"))
        // うるう日に入れたら、次の年の 2 月 28 日
        let leap = try #require(Timestamp(rawValue: "2028-02-29T00:00:00Z"))
        #expect(ClaudeTokenRecord(storedAt: leap).expiresAt == Timestamp(rawValue: "2029-02-28T00:00:00Z"))
    }

    @Test func selfCheckWritesClaudeTokenExpiryFromRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenExpiryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-token.json")
        let secrets = InMemorySecretStore([.claudeToken: Data("sk-ant-oat01-x".utf8)])
        let clock = Self.now
        @Sendable func check(at now: Date) async -> SelfCheck {
            await MachineProbe(secrets: secrets, volume: directory, owners: { [] }, claudeTokenRecord: url, now: { now }).selfCheck()
        }
        // 記録が無ければ（前の版で入れた）期限を書かない
        #expect(await check(at: clock).claudeTokenExpiresAt == nil)
        try ClaudeTokenRecord(storedAt: Timestamp(clock.addingTimeInterval(-300 * 24 * 60 * 60))).save(to: url)
        #expect(ClaudeTokenRecord.load(from: url)?.storedAt == Timestamp(clock.addingTimeInterval(-300 * 24 * 60 * 60)))
        let current = await check(at: clock)
        #expect(current.claudeToken == .ok)
        #expect(current.claudeTokenExpiresAt == Timestamp(clock.addingTimeInterval(65 * 24 * 60 * 60)))
        // 記録には日付だけを書く
        #expect(try String(contentsOf: url, encoding: .utf8).contains("sk-ant") == false)
        // 1 年を過ぎたら期限切れ
        let expired = await check(at: clock.addingTimeInterval(70 * 24 * 60 * 60))
        #expect(expired.claudeToken == .expired)
    }
}
