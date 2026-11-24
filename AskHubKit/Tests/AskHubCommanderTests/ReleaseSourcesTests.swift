@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 配信したコミットの求め方・版の書き換え・Bundle ID と変更の読み取り・リリース文の決まり
struct ReleaseSourcesTests {
    static let upload = ReleaseCommitFinder.uploadWorkflow
    static let base = Date(timeIntervalSince1970: 1_792_324_800)
    static let commitA = String(repeating: "a", count: 40)
    static let commitB = String(repeating: "b", count: 40)

    static func run(_ number: Int, _ sha: String, start: Double, end: Double, path: String = upload) -> ActionsRun {
        ActionsRun(
            id: 19_000_000_000 + number,
            runNumber: number,
            path: path,
            headSHA: sha,
            event: "push",
            startedAt: base.addingTimeInterval(start * 60),
            updatedAt: base.addingTimeInterval(end * 60)
        )
    }

    // MARK: - コミット

    @Test func findsRunThatUploadedTheBuildEvenIfNumbersDiffer() {
        // おしかつカウントダウンの 1.0.0: ビルド (12) は、Xcode が採番した Upload の実行 13 のもの
        let runs = [Self.run(12, Self.commitB, start: 0, end: 25), Self.run(13, Self.commitA, start: 30, end: 55)]
        let found = ReleaseCommitFinder.find(in: runs, build: "12", uploadedAt: Self.base.addingTimeInterval(50 * 60))
        #expect(found == .found(runs[1]))
    }

    @Test func narrowsOverlappingRunsByRunNumber() {
        let runs = [Self.run(30, Self.commitB, start: 0, end: 40), Self.run(31, Self.commitA, start: 5, end: 45)]
        let found = ReleaseCommitFinder.find(in: runs, build: "31", uploadedAt: Self.base.addingTimeInterval(38 * 60))
        #expect(found == .found(runs[1]))
        // 番号でも絞れなければ決めない
        #expect(ReleaseCommitFinder.find(in: runs, build: "7", uploadedAt: Self.base.addingTimeInterval(38 * 60)) == .ambiguous(runs))
    }

    @Test func picksAnyRunWhenOverlappingRunsShareTheCommit() {
        // develop と release/** で同じコミットが同時に走った
        let runs = [Self.run(13, Self.commitA, start: 0, end: 30), Self.run(14, Self.commitA, start: 1, end: 10)]
        #expect(ReleaseCommitFinder.find(in: runs, build: "12", uploadedAt: Self.base.addingTimeInterval(20 * 60)) == .found(runs[1]))
        #expect(ReleaseCommitFinder.find(in: runs, build: "13", uploadedAt: Self.base.addingTimeInterval(20 * 60)) == .found(runs[0]))
    }

    @Test func ignoresOtherWorkflowsAndRunsOutsideTheUpload() {
        let runs = [
            Self.run(40, Self.commitA, start: 0, end: 30, path: ".github/workflows/build.yml"),
            Self.run(41, Self.commitB, start: 60, end: 90)
        ]
        #expect(ReleaseCommitFinder.find(in: runs, build: "40", uploadedAt: Self.base.addingTimeInterval(20 * 60)) == .notFound)
        // 終わりの後のゆとり（15 分）の中なら候補にする
        #expect(ReleaseCommitFinder.find(in: runs, build: "41", uploadedAt: Self.base.addingTimeInterval(100 * 60)) == .found(runs[1]))
        #expect(ReleaseCommitFinder.find(in: runs, build: "41", uploadedAt: Self.base.addingTimeInterval(110 * 60)) == .notFound)
    }

    @Test func findsBuildNumberInUploadLog() {
        let build = "20261123.114349"
        // `${{ }}` で渡した xcodebuild の引数（ログで展開される）と、xcodebuild が出すコマンドラインのビルドの設定
        #expect(ReleaseCommitFinder.logShowsBuild("2026-11-23T11:43:49.0Z     CURRENT_PROJECT_VERSION=\(build) \\\n", build: build))
        let settings = "Build settings from command line:\n    CURRENT_PROJECT_VERSION = \(build)\n"
        #expect(ReleaseCommitFinder.logShowsBuild(settings, build: build))
        #expect(ReleaseCommitFinder.logShowsBuild(#"build_settings+=("CURRENT_PROJECT_VERSION=31")"#, build: "31"))
        // GitHub は `Run` の見出しのスクリプトを色付きで出す（字下げの無い行は、色の直後に名前が来る）
        #expect(ReleaseCommitFinder.logShowsBuild("\u{1B}[36;1m  CURRENT_PROJECT_VERSION=\(build)\u{1B}[0m\n", build: build))
        #expect(ReleaseCommitFinder.logShowsBuild("\u{1B}[36;1mCURRENT_PROJECT_VERSION=\(build)\u{1B}[0m\n", build: build))
        // 前の行に違う番号があっても、後ろで見つかればよい
        #expect(ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION=1\nCURRENT_PROJECT_VERSION = \(build)", build: build))
    }

    @Test func ignoresOtherBuildNumbersAndSettingsInUploadLog() {
        let build = "20261123.114349"
        #expect(!ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION=20261123.1143490", build: build))
        #expect(!ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION=120261123.114349", build: build))
        #expect(!ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION=${{ steps.build_number.outputs.value }}", build: build))
        #expect(!ReleaseCommitFinder.logShowsBuild("MY_CURRENT_PROJECT_VERSION=31", build: "31"))
        #expect(!ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION_SUFFIX=31", build: "31"))
        #expect(!ReleaseCommitFinder.logShowsBuild("Upload build 31 succeeded", build: "31"))
        #expect(!ReleaseCommitFinder.logShowsBuild("CURRENT_PROJECT_VERSION=", build: ""))
    }

    @Test func picksConfirmedRunOnlyWhenCommitsAgree() {
        let runs = [Self.run(39, Self.commitA, start: 0, end: 40), Self.run(40, Self.commitA, start: 1, end: 41)]
        #expect(ReleaseCommitFinder.pick(confirmed: runs) == runs[1])
        #expect(ReleaseCommitFinder.pick(confirmed: runs + [Self.run(41, Self.commitB, start: 2, end: 42)]) == nil)
        #expect(ReleaseCommitFinder.pick(confirmed: []) == nil)
    }

    // MARK: - 版

    @Test func replacesReleasedVersionInBuildSettings() throws {
        let released = try #require(MarketingVersion(rawValue: "1.0.0"))
        let next = released.nextMinor
        let xcconfig = "// 版\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n"
        #expect(MarketingVersionEdit.replacing(in: xcconfig, atMost: released, with: next)
            == "// 版\nMARKETING_VERSION = 1.1.0\nCURRENT_PROJECT_VERSION = 1\n")
        let pbxproj = "\t\t\t\tMARKETING_VERSION = 1.0.0;\n\t\t\t\tMARKETING_VERSION = \"0.9\";\n"
            + "\t\t\t\tMARKETING_VERSION = \"$(APP_VERSION)\";\n"
        #expect(MarketingVersionEdit.replacing(in: pbxproj, atMost: released, with: next)
            == "\t\t\t\tMARKETING_VERSION = 1.1.0;\n\t\t\t\tMARKETING_VERSION = \"1.1.0\";\n"
            + "\t\t\t\tMARKETING_VERSION = \"$(APP_VERSION)\";\n")
        let yaml = "settings:\n  MARKETING_VERSION: \"1.0.0\"\n"
        #expect(MarketingVersionEdit.replacing(in: yaml, atMost: released, with: next) == "settings:\n  MARKETING_VERSION: \"1.1.0\"\n")
        // もう大きい版は書き換えない
        #expect(MarketingVersionEdit.replacing(in: "MARKETING_VERSION = 1.2.0\n", atMost: released, with: next) == nil)
        #expect(MarketingVersionEdit.versions(in: pbxproj).map(\.rawValue) == ["1.0.0", "0.9"])
    }

    @Test func currentVersionIsTheLargestWritten() {
        let snapshot = MarketingVersionSnapshot(head: Self.commitA, tree: Self.commitB, files: [
            .init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.0.0\n"),
            .init(path: "App.xcodeproj/project.pbxproj", content: "MARKETING_VERSION = 1.10.0;\n")
        ])
        #expect(snapshot.current?.rawValue == "1.10.0")
        #expect(MarketingVersionSnapshot(head: Self.commitA, tree: Self.commitB, files: []).current == nil)
    }

    @Test func readsBundleIdentifiersWithoutVariables() {
        let content = """
            // テストターゲットは $(APP_BUNDLE_IDENTIFIER).Tests
            APP_BUNDLE_IDENTIFIER = jp.shilokuma.OshiCon
            PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER).Widget
            \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "jp.shilokuma.AskHub";
              PRODUCT_BUNDLE_IDENTIFIER: jp.shilokuma.Kawarin // App
            PRODUCT_BUNDLE_IDENTIFIER = jp.shilokuma.OshiCon
            """
        #expect(BundleIdentifiers.values(in: content) == ["jp.shilokuma.OshiCon", "jp.shilokuma.AskHub", "jp.shilokuma.Kawarin"])
    }

    @Test func choosesBuildSettingFiles() {
        let listing = [
            "100644 blob \(Self.commitA)     120\tConfigs/Project.xcconfig",
            "100644 blob \(Self.commitB)   90000\tOshiCon.xcodeproj/project.pbxproj",
            "100644 blob \(Self.commitA)      40\tproject.yml",
            "100644 blob \(Self.commitA)      40\tPods/Target Support Files/A/A.xcconfig",
            "120000 blob \(Self.commitA)      10\tlinked.xcconfig",
            "100644 blob \(Self.commitA) 9999999\thuge/project.pbxproj",
            "100644 blob \(Self.commitA)      10\tREADME.md"
        ].joined(separator: "\0")
        #expect(GitRepositoryWorkspace.settingEntries(fromListing: listing).map(\.path) == [
            "Configs/Project.xcconfig", "OshiCon.xcodeproj/project.pbxproj", "project.yml"
        ])
    }

    // MARK: - 変更

    @Test func readsPullRequestTitlesFromFirstParentLog() {
        let log = [
            "\(Self.commitA)\u{1f}Merge pull request #77 from shariverse/epic/locales\u{1f}12 言語に対応する\n\n本文\u{1e}",
            "\n\(Self.commitB)\u{1f}[fix] 日付のずれを直す\u{1f}\u{1e}",
            "\nnot-a-commit\u{1f}x\u{1f}\u{1e}"
        ].joined()
        #expect(ReleaseHistory.changes(fromLog: log) == [
            .init(commit: Self.commitA, pullRequest: 77, title: "12 言語に対応する"),
            .init(commit: Self.commitB, title: "[fix] 日付のずれを直す")
        ])
    }

    @Test func previousTagIsTheLargestBelowTheVersion() throws {
        let version = try #require(MarketingVersion(rawValue: "1.2.0"))
        let tags = ["v1.0.0", "v1.1.0", "v1.10.0", "v1.2.0", "legacy-final", "v1.1"]
        #expect(ReleaseHistory.previousTag(among: tags, below: version) == "v1.1.0")
        #expect(ReleaseHistory.previousTag(among: ["legacy-final"], below: version) == nil)
    }

    // MARK: - リリース文の決まり

    @Test func refusesNotesWithLinksTokensAndInternalWords() {
        #expect(ReleaseNotesRules.problems("## 新しい機能\n- 予定に写真を付けられるようになりました").isEmpty)
        #expect(!ReleaseNotesRules.problems("詳しくは https://example.com を").isEmpty)
        #expect(!ReleaseNotesRules.problems("問い合わせは dev@example.com へ").isEmpty)
        #expect(!ReleaseNotesRules.problems("ghp_abcdefghijklmnop を使う").isEmpty)
        #expect(!ReleaseNotesRules.problems("コミット \(Self.commitA)").isEmpty)
        #expect(!ReleaseNotesRules.problems("AskHub の epic で作った").isEmpty)
        #expect(!ReleaseNotesRules.problems(" \n ").isEmpty)
    }
}
