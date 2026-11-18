@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os
import Testing

/// 保護の設定（`applyProtection`）を管理用のトークンで掛け、重なる保護を外し、ずれを点検する
struct ProtectionTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let adminToken = "github_pat_" + String(repeating: "a", count: 40)

    func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    func registered(protection: RepositoryFile.Protection = .init()) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, protection: protection, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        return store
    }

    func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    private func envelope(checks: [String] = ["build / build"]) -> IntentEnvelope {
        IntentEnvelope(
            kind: ApplyProtectionIntent.kind,
            repo: Self.repo,
            payload: ["requiredChecks": .array(checks.map(JSONValue.string))],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func admin(_ transport: StubTransport, tokens: AdminTokens? = nil) -> AdminGitHub {
        AdminGitHub(tokens: tokens ?? AdminTokens { _ in Self.adminToken }, transport: transport)
    }

    static func ruleset(id: Int, name: String, source: String = "Repository", includes: [String], checks: [String] = []) -> String {
        let contexts = checks.map { #"{"context":"\#($0)","integration_id":15368}"# }.joined(separator: ",")
        return """
            {"id":\(id),"name":"\(name)","target":"branch","source_type":"\(source)","source":"x","enforcement":"active",
             "conditions":{"ref_name":{"include":[\(includes.map { "\"\($0)\"" }.joined(separator: ","))],"exclude":[]}},
             "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
                      {"type":"pull_request","parameters":{"required_approving_review_count":0}},
                      {"type":"required_status_checks",
                       "parameters":{"required_status_checks":[\(contexts)],"do_not_enforce_on_create":true}}],
             "bypass_actors":[]}
            """
    }

    static let classicRules = """
        {"repository":{"branchProtectionRules":{
          "nodes":[{"id":"BPR1","pattern":"develop"},{"id":"BPR2","pattern":"gh-pages"},{"id":"BPR3","pattern":"release/v*"}],
          "pageInfo":{"hasNextPage":false,"endCursor":null}}}}
        """

    /// クラシックの保護の一覧の応答（1 ページ）
    static func classicRules(_ nodes: String) -> String {
        #"{"repository":{"branchProtectionRules":{"nodes":\#(nodes),"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
    }

    static let protectedRefs = ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**/*"]

    static let ours = ruleset(
        id: 10, name: "askhub-protect", includes: protectedRefs, checks: ["build / build"]
    )

    // MARK: - 掛ける

    @Test func appliesRulesetThenReplacesOverlappingProtection() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
            .json(200, """
                [{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"},
                 {"id":11,"name":"protect-develop","target":"branch","source_type":"Repository","source":"x"},
                 {"id":12,"name":"org-default","target":"branch","source_type":"Organization","source":"shilokuma-inc"},
                 {"id":13,"name":"feature","target":"branch","source_type":"Repository","source":"x"},
                 {"id":14,"name":"tags","target":"tag","source_type":"Repository","source":"x"}]
                """),
            .json(200, Self.ours),
            .json(200, Self.ruleset(id: 11, name: "protect-develop", includes: ["refs/heads/develop"])),
            .json(204, ""),
            .json(200, Self.ruleset(id: 12, name: "org-default", source: "Organization", includes: ["~DEFAULT_BRANCH"])),
            .json(200, Self.ruleset(id: 13, name: "feature", includes: ["refs/heads/feature/*"])),
            .data(Self.classicRules),
            .data(#"{"deleteBranchProtectionRule":{"clientMutationId":null}}"#),
            .data(#"{"deleteBranchProtectionRule":{"clientMutationId":null}}"#)
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        #expect(decision == .accept)
        let requests = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(requests == [
            "GET /repos/shilokuma-inc/askhub-sandbox",
            "GET /repos/shilokuma-inc/askhub-sandbox/rulesets",
            // 先に掛けてから外す（同じ名前のルールセットは置き換える）
            "PUT /repos/shilokuma-inc/askhub-sandbox/rulesets/10",
            "GET /repos/shilokuma-inc/askhub-sandbox/rulesets/11",
            "DELETE /repos/shilokuma-inc/askhub-sandbox/rulesets/11",
            "GET /repos/shilokuma-inc/askhub-sandbox/rulesets/12",
            "GET /repos/shilokuma-inc/askhub-sandbox/rulesets/13",
            "POST /graphql",
            "POST /graphql",
            "POST /graphql"
        ])
        // 管理用のトークンだけを使う
        #expect(Set(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }) == ["Bearer \(Self.adminToken)"])
        try expectPolicyBody(try #require(transport.bodies.first))
        // 重なるクラシックの保護だけを外す（gh-pages は残す）
        #expect(transport.bodies.suffix(2).map { $0["variables"]?["id"] } == [.string("BPR1"), .string("BPR3")])

        let protection = try #require(try await repository(in: store)?.protection)
        #expect(protection.appliedAt == Timestamp(Self.now))
        #expect(protection.requiredChecks == ["build / build"])
        #expect(protection.rulesetId == 10)
        #expect(protection.replaced == [
            .init(kind: .ruleset, name: "protect-develop"),
            .init(kind: .classic, name: "develop"),
            .init(kind: .classic, name: "release/v*")
        ])
        #expect(protection.remaining == [
            .init(kind: .organizationRuleset, name: "org-default", reason: "organization のルールセットは、リポジトリの側からは外せない")
        ])
        #expect(protection.drift == nil)
    }

    /// 掛けるルールセットは、手で掛けてきたものと同じ中身（例外なし・承認 0・GitHub Actions のチェック・作るときは止めない）
    private func expectPolicyBody(_ body: JSONValue) throws {
        #expect(body["name"] == .string("askhub-protect"))
        #expect(body["bypass_actors"] == .array([]))
        #expect(body["enforcement"] == .string("active"))
        #expect(body["conditions"]?["ref_name"]?["include"] == .array([
            .string("refs/heads/develop"), .string("refs/heads/main"), .string("refs/heads/release/**/*")
        ]))
        let rules = try #require(body["rules"].flatMap { value -> [JSONValue]? in
            if case let .array(items) = value { return items }
            return nil
        })
        let types = ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]
        // 並びが違えば、添字で読む前に止める
        try #require(rules.map { $0["type"] } == types.map(JSONValue.string))
        #expect(rules[2]["parameters"]?["required_approving_review_count"] == .integer(0))
        #expect(rules[3]["parameters"]?["do_not_enforce_on_create"] == .bool(true))
        #expect(rules[3]["parameters"]?["required_status_checks"] == .array([
            .object(["context": .string("build / build"), "integration_id": .integer(15_368)])
        ]))
    }

    /// 掛けられなければ、何も外さずに理由を付けて断る（private のリポジトリは、今のプランではルールセットを掛けられない）
    @Test func refusesWithoutRemovingWhenRulesetCannotBeApplied() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"main","private":true}"#),
            .json(200, "[]"),
            .json(403, #"{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature."}"#)
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない: \(decision)")
            return
        }
        #expect(reason.hasPrefix("shilokuma-inc/askhub-sandbox は private のリポジトリで、今のプランではルールセットを掛けられない（GitHub: Upgrade"))
        #expect(transport.requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        #expect(try await repository(in: store)?.protection == RepositoryFile.Protection())
    }

    /// 管理用のトークンが無い持ち主・管理用のトークンを持たない司令塔・加えていないリポジトリは、GitHub に送らずに断る
    @Test func refusesWithoutAdminTokenOrRepository() async throws {
        let store = try await registered()
        let transport = StubTransport([])
        let missing = admin(transport, tokens: AdminTokens { _ in nil })
        #expect(try await ApplyProtectionHandler(admin: missing).handle(envelope(), in: context(store))
            == .reject("shilokuma-inc の管理用のトークンが無い（常時オンの Mac で askhub-commander admin-token shilokuma-inc を流して入れる）"))
        let none = try await ApplyProtectionHandler(admin: nil).handle(envelope(), in: context(store))
        #expect(none == .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）"))
        let empty = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(InMemoryStateStore()))
        #expect(empty == .reject("shilokuma-inc/askhub-sandbox は対象のリポジトリに加えていない。先に対象に加える"))
        var removed = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        removed.removedAt = Timestamp(Self.now)
        let removedStore = InMemoryStateStore()
        await removedStore.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(removed))
        #expect(try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(removedStore))
            == .reject("shilokuma-inc/askhub-sandbox は対象から外した。保護を掛けるには加え直す"))
        let malformed = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(checks: []), in: context(store))
        #expect(malformed == .reject("保護の設定の形が違う（必須のチェックが無い（1 つ以上要る））"))
        #expect(transport.requests.isEmpty)
    }

    /// 掛けた後に重なる保護を外しきれなければ、掛けたことを書いた上で、押し直すよう理由を付けて断る
    @Test func recordsAppliedRulesetEvenWhenReplacingFails() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, "[]"),
            .json(201, Self.ours),
            .json(403, #"{"message":"Resource not accessible by personal access token"}"#)
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない: \(decision)")
            return
        }
        #expect(reason.hasPrefix("ルールセットは掛けたが、重なる保護を外しきれなかった: クラシックの保護を読めない"))
        #expect(transport.requests.map(\.httpMethod) == ["GET", "GET", "POST", "POST"])
        let protection = try #require(try await repository(in: store)?.protection)
        #expect(protection.appliedAt == Timestamp(Self.now))
        #expect(protection.rulesetId == 10)
    }

    /// 範囲の外も守るクラシックの保護は外さず、わけを添えて残す
    @Test func keepsBroaderClassicProtection() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, "[]"),
            .json(201, Self.ours),
            .data(Self.classicRules(#"[{"id":"BPR1","pattern":"*"}]"#))
        ])
        #expect(try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store)) == .accept)
        #expect(transport.requests.count == 4)
        let protection = try #require(try await repository(in: store)?.protection)
        #expect(protection.replaced?.isEmpty == true)
        #expect(protection.remaining == [.init(kind: .classic, name: "*", reason: ProtectionApplier.broaderReason)])
    }

    /// GitHub の上限に当たったら、同じトークンで続けて送らずに止め、掛け直すと前に外したものも残す
    @Test func stopsAtRateLimitAndKeepsReplacedOnRetry() async throws {
        let applied = RepositoryFile.Protection(
            appliedAt: Timestamp(Self.now),
            requiredChecks: ["build / build"],
            rulesetId: 10,
            replaced: [.init(kind: .classic, name: "develop")]
        )
        let store = try await registered(protection: applied)
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, """
                [{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"},
                 {"id":11,"name":"old-develop","target":"branch","source_type":"Repository","source":"x"},
                 {"id":12,"name":"old-main","target":"branch","source_type":"Repository","source":"x"}]
                """),
            .json(200, Self.ours),
            .json(200, Self.ruleset(id: 11, name: "old-develop", includes: ["refs/heads/develop"])),
            .json(204, ""),
            .json(429, #"{"message":"rate limited"}"#, headers: ["Retry-After": "120"])
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        guard case let .reject(reason) = decision else {
            Issue.record("断っていない: \(decision)")
            return
        }
        #expect(reason.contains("GitHub の上限に当たったので、残りの保護を確かめずに止めた（120 秒ほど待ってから押し直す）"))
        // 上限の後は、クラシックの保護の一覧も読まない
        #expect(transport.requests.count == 6)
        let protection = try #require(try await repository(in: store)?.protection)
        #expect(protection.replaced == [.init(kind: .classic, name: "develop"), .init(kind: .ruleset, name: "old-develop")])
    }

    /// 外そうとして断られた保護は、わけを添えて残したものに書く
    @Test func recordsProtectionThatCouldNotBeRemoved() async throws {
        let store = try await registered()
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false}"#),
            .json(200, #"[{"id":11,"name":"old-develop","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(201, Self.ours),
            .json(200, Self.ruleset(id: 11, name: "old-develop", includes: ["refs/heads/develop"])),
            .json(403, #"{"message":"Resource not accessible"}"#),
            .data(Self.classicRules("[]"))
        ])
        let decision = try await ApplyProtectionHandler(admin: admin(transport)).handle(envelope(), in: context(store))
        guard case .reject = decision else {
            Issue.record("断っていない: \(decision)")
            return
        }
        let remaining = try #require(try await repository(in: store)?.protection.remaining)
        #expect(remaining.map(\.name) == ["old-develop"])
        #expect(remaining.first?.reason?.hasPrefix("外せなかった") == true)
    }

    // MARK: - ずれ

    /// 次のページのカーソルが同じものを繰り返したら、追いきれないので失敗にする（同じページを読み続けない）
    @Test func classicRulesPaginationStopsOnRepeatedCursor() async throws {
        let page = #"{"repository":{"branchProtectionRules":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}"#
        let transport = StubTransport([.data(page), .data(page), .data(page)])
        let github = GitHubPullRequests(repository: Self.repo, transport: transport) { _ in "t" }
        await #expect(throws: PullRequestError.malformed("branchProtectionRules の次のページを追えない")) {
            try await github.branchProtectionRules()
        }
        #expect(transport.requests.count == 2)
    }
}
