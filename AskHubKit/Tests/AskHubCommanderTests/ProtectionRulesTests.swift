@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 今ある保護との重なり（外すか・残すか）と、掛けたルールセットのずれの見分け方（GitHub を使わない所）
struct ProtectionRulesTests {
    // MARK: - 重なり

    @Test(arguments: [
        ("develop", ProtectionRules.Coverage.within), ("main", .within), ("release/*", .within), ("release/v*", .within),
        ("release/**/*", .within), ("*", .broader), ("**", .broader), ("dev*", .broader), ("r[e]lease/v*", .broader),
        ("master", .disjoint), ("release", .disjoint), ("feature/*", .disjoint), ("gh-pages", .disjoint), ("renewal", .disjoint)
    ])
    func classicPatternCoverage(pattern: String, coverage: ProtectionRules.Coverage) {
        #expect(ProtectionRules.coverage(classic: pattern) == coverage)
    }

    @Test func rulesetCoverageReadsSpecialTargetsAndExcludes() {
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
        #expect(ProtectionRules.coverage(ruleset: ruleset(["refs/heads/develop"]), defaultBranch: "main") == .within)
        #expect(ProtectionRules.coverage(ruleset: ruleset(["~DEFAULT_BRANCH"]), defaultBranch: "develop") == .within)
        #expect(ProtectionRules.coverage(ruleset: ruleset(["refs/heads/release/v*"]), defaultBranch: "main") == .within)
        // 守る範囲の外も守るものは外さない（ほかのブランチの保護が消えるため）
        #expect(ProtectionRules.coverage(ruleset: ruleset(["~ALL"]), defaultBranch: "main") == .broader)
        let withStable = ruleset(["refs/heads/develop", "refs/heads/stable"])
        #expect(ProtectionRules.coverage(ruleset: withStable, defaultBranch: "main") == .broader)
        // release/ を含んでも除外していれば、実際に守るのは stable だけで、重ならない（外さない）
        let releaseExcluded = ruleset(["refs/heads/release/**/*", "refs/heads/stable"], excludes: ["refs/heads/release/**/*"])
        #expect(ProtectionRules.coverage(ruleset: releaseExcluded, defaultBranch: "main") == .disjoint)
        // 守る範囲の外の既定のブランチだけ・ほかの名前だけ・守る範囲を除いた残りは、重ならない
        #expect(ProtectionRules.coverage(ruleset: ruleset(["~DEFAULT_BRANCH"]), defaultBranch: "trunk") == .disjoint)
        #expect(ProtectionRules.coverage(ruleset: ruleset(["refs/heads/feature/**/*"]), defaultBranch: "main") == .disjoint)
        let everythingElse = ruleset(["~ALL"], excludes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/**/*"])
        #expect(ProtectionRules.coverage(ruleset: everythingElse, defaultBranch: "main") == .disjoint)
        // 決まった名前は、除外に合えば重ならない（実際に守るのは stable だけ）
        let developExcluded = ruleset(["refs/heads/develop", "refs/heads/stable"], excludes: ["refs/heads/dev*"])
        #expect(ProtectionRules.coverage(ruleset: developExcluded, defaultBranch: "main") == .disjoint)
    }

    /// 除外が例の名前だけを外していても、release/ の下のほかの名前（release/v2 など）を守るなら重なる
    @Test func rulesetCoverageDoesNotTrustSampleNamesOnly() {
        func ruleset(_ includes: [String], excludes: [String]) -> Ruleset {
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
        let samples = ProtectionRules.sampleBranches.map { "refs/heads/\($0)" }
        #expect(ProtectionRules.coverage(ruleset: ruleset(["~ALL"], excludes: samples), defaultBranch: "main") == .broader)
        // release/ の下を 1 階層だけ外しても、深い名前（release/mobile/2.0）は残る
        let shallow = ruleset(["~ALL"], excludes: ["refs/heads/develop", "refs/heads/main", "refs/heads/release/*"])
        #expect(ProtectionRules.coverage(ruleset: shallow, defaultBranch: "main") == .broader)
        let releases = ruleset(
            ["refs/heads/release/*", "refs/heads/master"], excludes: ["refs/heads/release/1.0.0", "refs/heads/release/x"]
        )
        #expect(ProtectionRules.coverage(ruleset: releases, defaultBranch: "main") == .broader)
        // 深さによらず外す除外があれば、release/ の下だけを守る対象は重ならない
        let deep = ruleset(["refs/heads/release/v*", "refs/heads/master"], excludes: ["refs/heads/**/*"])
        #expect(ProtectionRules.coverage(ruleset: deep, defaultBranch: "main") == .disjoint)
    }

    /// GitHub と同じく、`*` と末尾の `**` は `/` をまたがず、`**/` は 0 個以上の階層にまたがる
    @Test func globFollowsGitHubPathnameRules() {
        #expect(Glob.matches("release/**/*", "release/1.0"))
        #expect(Glob.matches("release/**/*", "release/mobile/1.0"))
        #expect(!Glob.matches("release/**/*", "feature/1.0"))
        #expect(!Glob.matches("release/**", "release/1.0/hotfix"))
        #expect(!Glob.matches("release/*", "release/1.0/hotfix"))
        #expect(Glob.matches("v[0-9].?", "v1.x"))
        #expect(!Glob.matches("v[!0-9]", "v1"))
        #expect(Glob.matches("a.b", "a.b") && !Glob.matches("a.b", "aXb"))
        #expect(Glob.literalPrefix("release/v*") == "release/v")
    }

    // MARK: - ずれ

    @Test func driftListsWhatChangedFromPolicy() throws {
        let checks = Ruleset.Rule.requiredStatusChecks(
            StatusChecksRule(checks: [.init(context: "build / build", integrationID: 15_368)], doNotEnforceOnCreate: true)
        )
        let fine = Ruleset(
            id: 10,
            name: "askhub-protect",
            source: .repository,
            enforcement: "active",
            includes: ProtectionTests.protectedRefs,
            excludes: [],
            rules: [.deletion, .nonFastForward, .pullRequest(PullRequestRule(requiredApprovals: 0)), checks],
            bypassActorCount: nil
        )
        #expect(ProtectionRules.drift(of: fine, requiredChecks: ["build / build"]).isEmpty)
        var changed = fine
        changed.enforcement = "evaluate"
        changed.includes = ["refs/heads/develop"]
        changed.rules = [
            .pullRequest(PullRequestRule(requiredApprovals: 1, codeOwnerReview: true, lastPushApproval: true, threadResolution: true)),
            .requiredStatusChecks(
                StatusChecksRule(checks: [.init(context: "build / build", integrationID: nil)], doNotEnforceOnCreate: false)
            )
        ]
        changed.bypassActorCount = 1
        #expect(ProtectionRules.drift(of: changed, requiredChecks: ["build / build"]) == [
            "ルールセット askhub-protect が有効でない（evaluate）",
            "ルールセット askhub-protect の対象のブランチが変わった",
            "ブランチの削除が禁止されていない",
            "force push が禁止されていない",
            "PR に承認が要る（同じアカウントでは承認できず、マージが止まる）",
            "コードオーナーの承認が要る（マージが止まる）",
            "最後の push の後の承認が要る（マージが止まる）",
            "会話をすべて解決する必要がある（未解決のレビューのスレッドでマージが止まる）",
            "GitHub Actions 以外も必須のチェックを出せる（build / build）",
            "ブランチを作るときに必須のチェックで止まる（release/ のブランチを作れない）",
            "例外（bypass）が足された"
        ])
        // 説明は 1 つ 500 文字に収める（repo.json に書けるように）
        var many = fine
        let long = (1...20).map { Ruleset.RequiredCheck(context: String(repeating: "c", count: 200) + "\($0)", integrationID: 15_368) }
        many.rules = [.requiredStatusChecks(StatusChecksRule(checks: long))]
        #expect(ProtectionRules.drift(of: many, requiredChecks: ["build / build"]).allSatisfy { $0.count <= 500 })
    }
}
