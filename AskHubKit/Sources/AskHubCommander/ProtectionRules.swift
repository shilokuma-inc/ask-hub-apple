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

    /// 重なるかを確かめるブランチの例。守るブランチと既定のブランチ（`release/**` は例の名前で確かめ、`release/` で始まるパターンも重なるとみなす）
    static func sampleBranches(defaultBranch: String) -> [String] {
        var branches = ["develop", "main", "release/1.0.0", "release/x"]
        if !branches.contains(defaultBranch) { branches.append(defaultBranch) }
        return branches
    }

    /// クラシックの保護のパターンが、守るブランチに重なるか
    static func overlaps(classic pattern: String, defaultBranch: String) -> Bool {
        if pattern.hasPrefix("release/") { return true }
        return sampleBranches(defaultBranch: defaultBranch).contains { Glob.matches(pattern, $0) }
    }

    /// ルールセットの対象が、守るブランチに重なるか（`~ALL`・`~DEFAULT_BRANCH`・`refs/heads/…` のパターン）
    static func overlaps(ruleset: Ruleset, defaultBranch: String) -> Bool {
        if ruleset.includes.contains(where: { $0.hasPrefix("refs/heads/release/") }) { return true }
        return sampleBranches(defaultBranch: defaultBranch).contains { branch in
            let matches = { (pattern: String) in refPattern(pattern, matches: branch, defaultBranch: defaultBranch) }
            return ruleset.includes.contains(where: matches) && !ruleset.excludes.contains(where: matches)
        }
    }

    private static func refPattern(_ pattern: String, matches branch: String, defaultBranch: String) -> Bool {
        switch pattern {
        case "~ALL": return true
        case "~DEFAULT_BRANCH": return branch == defaultBranch
        default: return Glob.matches(pattern, "refs/heads/\(branch)")
        }
    }

    /// 掛けたルールセットが決まりの形からずれているところ（人が読む文）。ずれていなければ空
    static func drift(of ruleset: Ruleset, requiredChecks: [String]) -> [String] {
        var problems: [String] = []
        if ruleset.enforcement != "active" { problems.append("ルールセット \(ruleset.name) が有効でない（\(ruleset.enforcement)）") }
        let expected = Set(ProtectionPolicy.branches.map { "refs/heads/\($0)" })
        if Set(ruleset.includes) != expected || !ruleset.excludes.isEmpty {
            problems.append("ルールセット \(ruleset.name) の対象のブランチが変わった")
        }
        if !ruleset.rules.contains(.deletion) { problems.append("ブランチの削除が禁止されていない") }
        if !ruleset.rules.contains(.nonFastForward) { problems.append("force push が禁止されていない") }
        let approvals = ruleset.rules.compactMap { rule -> Int? in
            if case let .pullRequest(count) = rule { return count }
            return nil
        }
        if approvals.isEmpty {
            problems.append("PR が必須でない")
        } else if approvals.contains(where: { $0 > 0 }) {
            problems.append("PR に承認が要る（同じアカウントでは承認できず、マージが止まる）")
        }
        let checks = ruleset.rules.flatMap { rule -> [String] in
            if case let .requiredStatusChecks(checks) = rule { return checks.map(\.context) }
            return []
        }
        if Set(checks) != Set(requiredChecks) {
            problems.append("必須のチェックが変わった（今は \(checks.isEmpty ? "無し" : checks.joined(separator: "・"))）")
        }
        if let count = ruleset.bypassActorCount, count > 0 { problems.append("例外（bypass）が足された") }
        return problems
    }
}

/// fnmatch の形のパターン（`*` は `/` をまたがない、`**` はまたぐ、`?` は 1 文字、`[…]` は文字の組）
enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(expression(of: pattern)) else { return false }
        return text.wholeMatch(of: regex) != nil
    }

    private static func expression(of pattern: String) -> String {
        var result = ""
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    result += ".*"
                } else {
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
