@testable import AskHubKit
import Foundation
import Testing

struct ReleaseVersionTests {
    @Test(arguments: ["0.0.0", "1.0.0", "1.10.3", "10.0.12", "2026.1.0"])
    func acceptsMajorMinorPatch(_ text: String) throws {
        let version = try #require(ReleaseVersion(text))
        #expect(version.description == text)
    }

    @Test(arguments: [
        "", "1", "1.0", "1.0.0.0", "1..0", ".1.0", "1.0.", "01.0.0", "1.00.0", "1.0.01",
        "-1.0.0", "+1.0.0", "1.0.0 ", " 1.0.0", "v1.0.0", "1.0.0-beta", "１.０.０", "1.a.0", "99999999999999999999.0.0"
    ])
    func rejectsOtherForms(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func computesNextMinor() throws {
        #expect(try #require(ReleaseVersion("1.0.0")).nextMinor == ReleaseVersion(major: 1, minor: 1, patch: 0))
        #expect(try #require(ReleaseVersion("1.9.7")).nextMinor.description == "1.10.0")
        #expect(try #require(ReleaseVersion("0.0.3")).nextMinor.description == "0.1.0")
    }

    @Test func namesBranchAndTag() throws {
        let version = try #require(ReleaseVersion("1.1.0"))
        #expect(version.branchName == "release/1.1.0")
        #expect(version.tagName == "v1.1.0")
        #expect(ReleaseVersion(branch: "release/1.1.0") == version)
        #expect(ReleaseVersion(tag: "v1.1.0") == version)
        #expect(ReleaseVersion(branch: "release/foo") == nil)
        #expect(ReleaseVersion(branch: "release-1.1.0") == nil)
        #expect(ReleaseVersion(branch: "v1.1.0") == nil)
        #expect(ReleaseVersion(tag: "very-old") == nil)
        #expect(ReleaseVersion(tag: "1.1.0") == nil)
    }

    @Test func comparesNumerically() throws {
        let versions = ["1.10.0", "1.2.0", "1.2.10", "1.2.9", "0.9.9"].compactMap { ReleaseVersion($0) }
        #expect(versions.sorted().map(\.description) == ["0.9.9", "1.2.0", "1.2.9", "1.2.10", "1.10.0"])
        #expect(try #require(ReleaseVersion("2.0.0")) > #require(ReleaseVersion("1.99.99")))
    }
}

struct MarketingVersionTests {
    @Test func readsMarketingVersionFromXcconfig() throws {
        let xcconfig = """
            // バージョン（CFBundleShortVersionString / CFBundleVersion）
            // MARKETING_VERSION = 0.0.1
            MARKETING_VERSION = 1.0.0
            CURRENT_PROJECT_VERSION = 1
            """
        let marketing = try #require(MarketingVersion.parse(xcconfig: xcconfig))
        #expect(marketing.raw == "1.0.0")
        #expect(marketing.version == ReleaseVersion("1.0.0"))
        #expect(marketing.nextMinor == ReleaseVersion("1.1.0"))
    }

    @Test func usesLastUnconditionalAssignmentAndStripsComments() throws {
        let xcconfig = "MARKETING_VERSION = 1.0.0\r\nMARKETING_VERSION[sdk=macosx*] = 9.9.9\r\n  MARKETING_VERSION=1.2.3 ; // 次のリリース\r\n"
        let marketing = try #require(MarketingVersion.parse(xcconfig: xcconfig))
        #expect(marketing.raw == "1.2.3")
        #expect(marketing.nextMinor?.description == "1.3.0")
    }

    @Test func keepsRawValueWhenFormDiffers() throws {
        let short = try #require(MarketingVersion.parse(xcconfig: "MARKETING_VERSION = 1.0"))
        #expect(short.raw == "1.0")
        #expect(short.version == nil)
        #expect(short.nextMinor == nil)
        let variable = try #require(MarketingVersion.parse(xcconfig: "MARKETING_VERSION = $(BASE_VERSION)"))
        #expect(variable.nextMinor == nil)
    }

    @Test func returnsNilWithoutMarketingVersion() {
        #expect(MarketingVersion.parse(xcconfig: "CURRENT_PROJECT_VERSION = 1\n// MARKETING_VERSION = 1.0.0") == nil)
        #expect(MarketingVersion.parse(xcconfig: "") == nil)
    }
}

struct ReleaseWorkflowTests {
    @Test func namesTheAgreedFiles() {
        #expect(ReleaseWorkflow.prepare.file == "release-prepare.yml")
        #expect(ReleaseWorkflow.notes.file == "release-notes.yml")
        #expect(ReleaseWorkflow.finish.file == "release-finish.yml")
        #expect(ReleaseWorkflow.sync.file == "release-sync.yml")
        let client = GitHubClient(token: "t", http: MockHTTPClient([]))
        #expect(ReleaseWorkflow.notes.client(client).file == "release-notes.yml")
    }

    @Test func buildsInputs() throws {
        let version = try #require(ReleaseVersion("1.1.0"))
        #expect(ReleaseWorkflow.prepareInputs(version: version) == ["version": "1.1.0"])
        #expect(ReleaseWorkflow.prepareInputs(version: version, resume: true) == ["version": "1.1.0", "resume": "true"])
        #expect(ReleaseWorkflow.finishInputs(version: version) == ["version": "1.1.0"])

        let inputs = try ReleaseWorkflow.notesInputs(version: version, whatsNew: ["ja": "・直した\n・足した \"新機能\" / URL", "en": "Fixes"])
        #expect(inputs["version"] == "1.1.0")
        // キーの順は固定。スラッシュはエスケープしない。読み戻すと同じ本文になる
        let json = try #require(inputs["whats_new"])
        #expect(json == #"{"en":"Fixes","ja":"・直した\n・足した \"新機能\" / URL"}"#)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        #expect(decoded == ["ja": "・直した\n・足した \"新機能\" / URL", "en": "Fixes"])
    }
}
