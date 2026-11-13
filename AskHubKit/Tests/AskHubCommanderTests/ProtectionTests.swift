@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 保護の設定（`applyProtection`）を管理用のトークンで掛け、重なる保護を外し、ずれを点検する
struct ProtectionTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let adminToken = "github_pat_" + String(repeating: "a", count: 40)

    private func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    private func registered(protection: RepositoryFile.Protection = .init()) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, protection: protection, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        return store
    }

    private func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
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
                      {"type":"required_status_checks","parameters":{"required_status_checks":[\(contexts)]}}],
             "bypass_actors":[]}
            """
    }

    static let classicRules = """
        {"repository":{"branchProtectionRules":{
          "nodes":[{"id":"BPR1","pattern":"develop"},{"id":"BPR2","pattern":"gh-pages"},{"id":"BPR3","pattern":"release/v*"}],
          "pageInfo":{"hasNextPage":false,"endCursor":null}}}}
        """

    static let protectedRefs = ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**"]

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
        #expect(protection.remaining == [.init(kind: .organizationRuleset, name: "org-default")])
        #expect(protection.drift == nil)
    }

    /// 掛けるルールセットは、手で掛けてきたものと同じ中身（例外なし・承認 0・GitHub Actions のチェック・作るときは止めない）
    private func expectPolicyBody(_ body: JSONValue) throws {
        #expect(body["name"] == .string("askhub-protect"))
        #expect(body["bypass_actors"] == .array([]))
        #expect(body["enforcement"] == .string("active"))
        #expect(body["conditions"]?["ref_name"]?["include"] == .array([
            .string("refs/heads/develop"), .string("refs/heads/main"), .string("refs/heads/release/**")
        ]))
        let rules = try #require(body["rules"].flatMap { value -> [JSONValue]? in
            if case let .array(items) = value { return items }
            return nil
        })
        let types = ["deletion", "non_fast_forward", "pull_request", "required_status_checks"]
        #expect(rules.map { $0["type"] } == types.map(JSONValue.string))
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

    // MARK: - 重なり

    @Test(arguments: [
        ("develop", true), ("main", true), ("release/*", true), ("release/v*", true), ("*", true), ("**", true),
        ("dev*", true), ("master", true), ("feature/*", false), ("gh-pages", false), ("renewal", false)
    ])
    func classicPatternOverlapsProtectedBranches(pattern: String, overlaps: Bool) {
        #expect(ProtectionRules.overlaps(classic: pattern, defaultBranch: "master") == overlaps)
    }

    @Test func rulesetOverlapReadsSpecialTargetsAndExcludes() {
        func ruleset(_ includes: [String], excludes: [String] = []) -> Ruleset {
            Ruleset(
                id: 1,
                name: "x",
                source: .repository,
                enforcement: "active",
                includes: includes,
                excludes: excludes,
                rules: [],
                bypassActorCount: 0
            )
        }
        #expect(ProtectionRules.overlaps(ruleset: ruleset(["~ALL"]), defaultBranch: "main"))
        #expect(ProtectionRules.overlaps(ruleset: ruleset(["~DEFAULT_BRANCH"]), defaultBranch: "trunk"))
        #expect(ProtectionRules.overlaps(ruleset: ruleset(["refs/heads/release/v*"]), defaultBranch: "main"))
        #expect(!ProtectionRules.overlaps(ruleset: ruleset(["refs/heads/feature/**"]), defaultBranch: "main"))
        let everythingElse = ruleset(["~ALL"], excludes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**"])
        #expect(!ProtectionRules.overlaps(ruleset: everythingElse, defaultBranch: "main"))
        #expect(Glob.matches("release/**", "release/1.0/hotfix"))
        #expect(!Glob.matches("release/*", "release/1.0/hotfix"))
        #expect(Glob.matches("v[0-9].?", "v1.x"))
        #expect(!Glob.matches("v[!0-9]", "v1"))
        #expect(Glob.matches("a.b", "a.b") && !Glob.matches("a.b", "aXb"))
    }

    // MARK: - ずれ

    @Test func driftListsWhatChangedFromPolicy() throws {
        let checks = Ruleset.Rule.requiredStatusChecks([.init(context: "build / build", integrationID: 15_368)])
        let fine = Ruleset(
            id: 10,
            name: "askhub-protect",
            source: .repository,
            enforcement: "active",
            includes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**"],
            excludes: [],
            rules: [.deletion, .nonFastForward, .pullRequest(requiredApprovals: 0), checks],
            bypassActorCount: nil
        )
        #expect(ProtectionRules.drift(of: fine, requiredChecks: ["build / build"]).isEmpty)
        var changed = fine
        changed.enforcement = "evaluate"
        changed.includes = ["refs/heads/develop"]
        changed.rules = [.pullRequest(requiredApprovals: 1), .requiredStatusChecks([])]
        changed.bypassActorCount = 1
        #expect(ProtectionRules.drift(of: changed, requiredChecks: ["build / build"]) == [
            "ルールセット askhub-protect が有効でない（evaluate）",
            "ルールセット askhub-protect の対象のブランチが変わった",
            "ブランチの削除が禁止されていない",
            "force push が禁止されていない",
            "PR に承認が要る（同じアカウントでは承認できず、マージが止まる）",
            "必須のチェックが変わった（今は 無し）",
            "例外（bypass）が足された"
        ])
    }

    /// 掛けたリポジトリだけを、毎日のトークンで読んで点検し、ずれが変わったときだけ書く
    @Test func watchWritesDriftOnlyWhenItChanges() async throws {
        let applied = RepositoryFile.Protection(appliedAt: Timestamp(Self.now), requiredChecks: ["build / build"], rulesetId: 10)
        let store = try await registered(protection: applied)
        let transport = StubTransport([
            // 1 回目: 必須のチェックが外された
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(
                id: 10, name: "askhub-protect", includes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**"]
            )),
            // 2 回目: 同じずれ（書かない）
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ruleset(
                id: 10, name: "askhub-protect", includes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**"]
            )),
            // 3 回目: 直った
            .json(200, #"[{"id":10,"name":"askhub-protect","target":"branch","source_type":"Repository","source":"x"}]"#),
            .json(200, Self.ours),
            // 4 回目: ルールセットごと外された
            .json(200, "[]")
        ])
        let watch = ProtectionWatch(
            context: context(store),
            github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "github_pat_daily" } },
            log: { _ in }
        )
        #expect(try await watch.check(Self.repo))
        let drift = ProtectionDrift(foundAt: Timestamp(Self.now), problems: ["必須のチェックが変わった（今は 無し）"])
        #expect(try await repository(in: store)?.protection.drift == drift)
        #expect(try await !watch.check(Self.repo))
        #expect(try await watch.check(Self.repo))
        #expect(try await repository(in: store)?.protection.drift == nil)
        #expect(try await watch.check(Self.repo))
        #expect(try await repository(in: store)?.protection.drift?.problems == ["ルールセット askhub-protect が無い（外された）"])
        // 点検は読むだけで、毎日のトークンを使う
        #expect(transport.requests.allSatisfy { request in
            request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_daily"
        })
        // 掛けた時刻・必須のチェックは変えない
        #expect(try await repository(in: store)?.protection.appliedAt == Timestamp(Self.now))
    }

    /// 保護を掛けていないリポジトリは点検しない
    @Test func watchSkipsRepositoriesWithoutProtection() async throws {
        let store = try await registered()
        let transport = StubTransport([])
        let watch = ProtectionWatch(
            context: context(store), github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "t" } }, log: { _ in }
        )
        #expect(try await !watch.check(Self.repo))
        #expect(transport.requests.isEmpty)
    }
}
