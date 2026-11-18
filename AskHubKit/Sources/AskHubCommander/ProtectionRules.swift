import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 掛けるルールセット（`ProtectionPolicy`）と、今ある保護との照らし合わせ（`docs/renewal/security.md` の「ブランチ保護」）
enum ProtectionRules {
    /// 掛けるルールセット
    static func draft(requiredChecks: [String]) -> RulesetDraft {
        RulesetDraft(
            name: ProtectionPolicy.rulesetName,
            includes: ProtectionPolicy.branches.map { "refs/heads/\($0)" },
            requiredChecks: requiredChecks,
            checksIntegrationID: ProtectionPolicy.githubActionsAppID
        )
    }

    /// 今ある保護が、掛けるルールセットの守る範囲とどう重なるか
    enum Coverage: Equatable {
        /// 守る範囲（develop・main・`release/` の下）に収まる。外しても、守られなくなるブランチは無い
        case within
        /// 守る範囲に重なるが、ほかのブランチも守る（かもしれない）。外すとほかのブランチの保護が消えるので、残して知らせる
        case broader
        /// 重ならない
        case disjoint
    }

    /// 重なるかを確かめるブランチの例（守る範囲の名前）
    static let sampleBranches = ["develop", "main", "release/1.0.0", "release/x", "release/mobile/1.0"]

    /// 守る範囲の名前。決まった名前か、`release/` の下
    private static func isProtected(_ branch: String) -> Bool {
        branch == "develop" || branch == "main" || branch.hasPrefix("release/")
    }

    /// クラシックの保護のパターンの重なり。守る範囲の外の名前（既定のブランチが `master` など）だけを守るものは、重ならない
    static func coverage(classic pattern: String) -> Coverage {
        let prefix = Glob.literalPrefix(pattern)
        if prefix == pattern { return isProtected(pattern) ? .within : .disjoint }
        // ワイルドカードの前の文字が `release/` で始まれば、合う名前はすべて `release/` の下
        if prefix.hasPrefix("release/") { return .within }
        return mayOverlap(prefix: prefix) || sampleBranches.contains(where: { Glob.matches(pattern, $0) }) ? .broader : .disjoint
    }

    /// ルールセットの対象の重なり（`~ALL`・`~DEFAULT_BRANCH`・`refs/heads/…` のパターン）。除外は対象を狭めるだけなので、
    /// 対象がすべて守る範囲に収まれば外してよい。収まらないものは、守る範囲に合うかもしれない対象を、除外がすべて外すと言い切れるときだけ
    /// 重ならないとみなす（例の名前だけでは、`release/` の下の深い名前まで確かめきれないため）
    static func coverage(ruleset: Ruleset, defaultBranch: String) -> Coverage {
        let includes = ruleset.includes.map { refCoverage($0, defaultBranch: defaultBranch) }
        if !includes.isEmpty, includes.allSatisfy({ $0 == .within }) { return .within }
        let overlaps = zip(ruleset.includes, includes).contains { pattern, coverage in
            coverage != .disjoint && !excludesCover(pattern, excludes: ruleset.excludes, defaultBranch: defaultBranch)
        }
        return overlaps ? .broader : .disjoint
    }

    /// 対象のパターンに合う守る範囲の名前を、除外がすべて外すと言い切れる。決まった名前は、その名前が除外に合うかで決める。
    /// ワイルドカード（`~ALL` を含む）は、`release/` の下を深さによらず外す除外（`release/**/*` など）があり、
    /// `release/` の下でないものは develop・main も外すときだけ
    private static func excludesCover(_ pattern: String, excludes: [String], defaultBranch: String) -> Bool {
        let isExcluded = { (branch: String) in excludes.contains { refPattern($0, matches: branch, defaultBranch: defaultBranch) } }
        if let branch = literalBranch(pattern, defaultBranch: defaultBranch) { return isExcluded(branch) }
        let releases = excludes.contains { ["~ALL", "refs/heads/**/*", "refs/heads/release/**/*"].contains($0) }
        if pattern.hasPrefix("refs/heads/release/") { return releases }
        return releases && isExcluded("develop") && isExcluded("main")
    }

    /// ワイルドカードを含まない対象のブランチの名前（`~DEFAULT_BRANCH` は既定のブランチ）
    private static func literalBranch(_ pattern: String, defaultBranch: String) -> String? {
        if pattern == "~DEFAULT_BRANCH" { return defaultBranch }
        guard pattern.hasPrefix("refs/heads/") else { return nil }
        let name = String(pattern.dropFirst("refs/heads/".count))
        return Glob.literalPrefix(name) == name ? name : nil
    }

    private static func refCoverage(_ pattern: String, defaultBranch: String) -> Coverage {
        switch pattern {
        case "~ALL": return .broader
        case "~DEFAULT_BRANCH": return isProtected(defaultBranch) ? .within : .disjoint
        default:
            guard pattern.hasPrefix("refs/heads/") else { return .broader }
            return coverage(classic: String(pattern.dropFirst("refs/heads/".count)))
        }
    }

    /// ワイルドカードの前の文字が、守る範囲の名前の先頭と食い違わない（合う名前があるかもしれない）
    private static func mayOverlap(prefix: String) -> Bool {
        ["develop", "main", "release/"].contains { $0.hasPrefix(prefix) || prefix.hasPrefix($0) }
    }

    private static func refPattern(_ pattern: String, matches branch: String, defaultBranch: String) -> Bool {
        switch pattern {
        case "~ALL": return true
        case "~DEFAULT_BRANCH": return branch == defaultBranch
        default: return Glob.matches(pattern, "refs/heads/\(branch)")
        }
    }

    /// 掛けたルールセットが決まりの形からずれているところ（人が読む文。1 つは 500 文字まで）。ずれていなければ空。
    /// 例外（bypass）は、管理の権限の無いトークンには見えない（`bypassActorCount` が nil）ので、見えたときだけ確かめる
    static func drift(of ruleset: Ruleset, requiredChecks: [String]) -> [String] {
        var problems: [String] = []
        if ruleset.enforcement != "active" { problems.append("ルールセット \(ruleset.name) が有効でない（\(ruleset.enforcement)）") }
        let expected = Set(ProtectionPolicy.branches.map { "refs/heads/\($0)" })
        if Set(ruleset.includes) != expected || !ruleset.excludes.isEmpty {
            problems.append("ルールセット \(ruleset.name) の対象のブランチが変わった")
        }
        if !ruleset.rules.contains(.deletion) { problems.append("ブランチの削除が禁止されていない") }
        if !ruleset.rules.contains(.nonFastForward) { problems.append("force push が禁止されていない") }
        problems += pullRequestDrift(ruleset.rules)
        problems += statusChecksDrift(ruleset.rules, requiredChecks: requiredChecks)
        if let count = ruleset.bypassActorCount, count > 0 { problems.append("例外（bypass）が足された") }
        return problems
    }

    /// PR 必須の規則のずれ。承認や会話の解決が要ると、同じアカウントだけではマージできなくなる
    private static func pullRequestDrift(_ rules: [Ruleset.Rule]) -> [String] {
        let pullRequests = rules.compactMap { rule -> PullRequestRule? in
            if case let .pullRequest(settings) = rule { return settings }
            return nil
        }
        guard !pullRequests.isEmpty else { return ["PR が必須でない"] }
        var problems: [String] = []
        if pullRequests.contains(where: { $0.requiredApprovals > 0 }) { problems.append("PR に承認が要る（同じアカウントでは承認できず、マージが止まる）") }
        if pullRequests.contains(where: \.codeOwnerReview) { problems.append("コードオーナーの承認が要る（マージが止まる）") }
        if pullRequests.contains(where: \.lastPushApproval) { problems.append("最後の push の後の承認が要る（マージが止まる）") }
        if pullRequests.contains(where: \.threadResolution) { problems.append("会話をすべて解決する必要がある（未解決のレビューのスレッドでマージが止まる）") }
        return problems
    }

    /// 必須のチェックの規則のずれ（名前・出してよいアプリ・ブランチを作るときに止めないか）
    private static func statusChecksDrift(_ rules: [Ruleset.Rule], requiredChecks: [String]) -> [String] {
        let settings = rules.compactMap { rule -> StatusChecksRule? in
            if case let .requiredStatusChecks(settings) = rule { return settings }
            return nil
        }
        let checks = settings.flatMap(\.checks)
        var problems: [String] = []
        if Set(checks.map(\.context)) != Set(requiredChecks) {
            let now = checks.isEmpty ? "無し" : checks.map(\.context).joined(separator: "・")
            problems.append("必須のチェックが変わった（今は \(now.count > 300 ? String(now.prefix(300)) + "…" : now)）")
        }
        let otherApps = checks.filter { $0.integrationID != ProtectionPolicy.githubActionsAppID }.map(\.context)
        if !otherApps.isEmpty {
            let names = otherApps.joined(separator: "・")
            problems.append("GitHub Actions 以外も必須のチェックを出せる（\(names.count > 300 ? String(names.prefix(300)) + "…" : names)）")
        }
        if settings.contains(where: { $0.doNotEnforceOnCreate == false }) {
            problems.append("ブランチを作るときに必須のチェックで止まる（release/ のブランチを作れない）")
        }
        return problems
    }
}

/// GitHub のパターン（Ruby の `File.fnmatch` に `FNM_PATHNAME`）。`*` と末尾の `**` は `/` をまたがない、`**/` は 0 個以上の
/// 階層にまたがる、`?` は 1 文字、`[…]` は文字の組
enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(expression(of: pattern)) else { return false }
        return text.wholeMatch(of: regex) != nil
    }

    /// 最初のワイルドカード（`*`・`?`・`[`）の前の文字。ワイルドカードが無ければパターンそのもの
    static func literalPrefix(_ pattern: String) -> String {
        String(pattern.prefix { !["*", "?", "["].contains($0) })
    }

    private static func expression(of pattern: String) -> String {
        var result = ""
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*", characters.dropFirst().first == "/" {
                    // `**/` は、0 個以上の階層
                    characters.removeFirst(2)
                    result += "(?:.*/)?"
                } else {
                    // `*` と、`/` の前でない `**` は、`/` をまたがない
                    while characters.first == "*" { characters.removeFirst() }
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case "[":
                // 閉じる `]` までを文字の組にする。閉じなければ文字として扱う
                guard let close = characters.firstIndex(of: "]") else {
                    result += "\\["
                    continue
                }
                let body = characters[characters.startIndex..<close].map { $0 == "\\" ? "\\\\" : String($0) }.joined()
                result += "[" + (body.hasPrefix("!") ? "^" + body.dropFirst() : body) + "]"
                characters = characters[characters.index(after: close)...]
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return result
    }
}
