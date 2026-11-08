import AskHubProtocol
import Foundation

/// 最終 PR の差分のパスから、決まった規則で見つける手動のマージの条件（`docs/renewal/flows.md` の「マージの規則」）。
///
/// レビュー役の Claude の見落としに頼らないよう、注意の要るパスに差分があれば `sensitivePaths` を足す。
/// 規則は迷ったら人の確認に倒す（人が確認してマージするだけで、壊れはしないため）
enum FinalMergeRisks {
    /// 注意の要るパスの区分。`matches` は、リポジトリの直下からのパスを `/` で分けたものと、ファイルの名前を受け取る
    struct Rule: Sendable {
        var label: String
        var matches: @Sendable (_ components: [Substring], _ name: String) -> Bool
    }

    /// 1 つの理由に載せるパスの数の上限（超えた分は数だけを書く）
    static let maximumPathsInReason = 5

    static let rules: [Rule] = [
        Rule(label: "GitHub のワークフローと設定（.github/）") { components, _ in components.first == ".github" },
        Rule(label: "Claude Code の設定（.claude/・.mcp.json）") { components, name in
            components.contains(".claude") || name == ".mcp.json"
        },
        Rule(label: "ビルド・CI・リリースのスクリプトと道具") { components, name in
            let folders: Set<Substring> = ["scripts", "ci_scripts", "fastlane", "bin", "Tuist"]
            let files: Set<String> = [
                "Makefile", "Fastfile", "Gemfile", "Gemfile.lock", "Brewfile", "Mintfile", "Dangerfile", "project.yml", "Project.swift",
                "Workspace.swift", ".swiftlint.yml", ".swiftformat", ".xcode-version"
            ]
            return components.dropLast().contains(where: folders.contains) || files.contains(name) || name.hasSuffix(".sh")
        },
        Rule(label: "依存とプラグイン（Package.swift・Package.resolved など）") { _, name in
            ["Package.swift", "Package.resolved", "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved"].contains(name)
        },
        Rule(label: "entitlements") { _, name in name.hasSuffix(".entitlements") },
        Rule(label: "Info.plist（権限）") { _, name in name == "Info.plist" || name.hasSuffix("-Info.plist") },
        Rule(label: "ビルドと署名の設定（.xcconfig・スキーム・テストの計画）") { _, name in
            [".xcconfig", ".xcscheme", ".xctestplan"].contains { name.hasSuffix($0) }
        },
        Rule(label: "署名とリリースのファイル") { _, name in
            [".mobileprovision", ".provisionprofile", ".p12", ".p8", ".cer"].contains { name.hasSuffix($0) }
                || (name.hasPrefix("ExportOptions") && name.hasSuffix(".plist"))
        },
        Rule(label: "トークン・Keychain・認証の情報を扱うと思われるファイル") { _, name in
            let lowered = name.lowercased()
            return ["keychain", "credential", "secret", "password", "token"].contains { lowered.contains($0) }
        }
    ]

    /// Xcode のプロジェクトの変わった行のうち、ビルドのスクリプト・依存・署名・権限の設定に当たるもの
    static let projectKeys = [
        "PBXShellScriptBuildPhase", "shellScript", "XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference",
        "XCSwiftPackageProductDependency", "CODE_SIGN", "DEVELOPMENT_TEAM", "PROVISIONING_PROFILE", "PRODUCT_BUNDLE_IDENTIFIER",
        "ENABLE_USER_SCRIPT_SANDBOXING", "INFOPLIST_FILE", "INFOPLIST_KEY_NS", "INFOPLIST_KEY_UIBackgroundModes", "buildRules"
    ]

    /// 差分のパスと Xcode のプロジェクトの変わった行から、手動のマージの条件を返す（区分ごとに 1 つ）
    static func risks(paths: [String], projectLines: [String]) -> [MergeRisk] {
        var risks = rules.compactMap { rule -> MergeRisk? in
            let matched = paths.filter { path in
                let components = path.split(separator: "/")
                return rule.matches(components, components.last.map(String.init) ?? path)
            }
            guard !matched.isEmpty else { return nil }
            return MergeRisk(kind: .sensitivePaths, reason: "\(rule.label)に差分がある: \(list(matched))")
        }
        let keys = projectKeys.filter { key in projectLines.contains { $0.contains(key) } }
        if !keys.isEmpty {
            let reason = "Xcode のプロジェクトの、ビルドのスクリプト・依存・署名・権限の設定に差分がある（\(keys.joined(separator: "・"))）"
            risks.append(MergeRisk(kind: .sensitivePaths, reason: reason))
        }
        return risks
    }

    private static func list(_ paths: [String]) -> String {
        let shown = paths.prefix(maximumPathsInReason).joined(separator: "・")
        return paths.count > maximumPathsInReason ? "\(shown) ほか \(paths.count - maximumPathsInReason) 件" : shown
    }

    /// レビュー役の Claude の材料と、決まった規則の材料を合わせる（同じものは 1 つにする）
    static func merged(_ first: [MergeRisk], _ second: [MergeRisk]) -> [MergeRisk] {
        var result: [MergeRisk] = []
        for risk in first + second where !result.contains(risk) {
            result.append(risk)
        }
        return result
    }
}
