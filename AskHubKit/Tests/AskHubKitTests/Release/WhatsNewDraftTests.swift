@testable import AskHubKit
import Foundation
import Testing

struct WhatsNewDraftTests {
    static let draftJSON = #"""
        {
          "schemaVersion": 1,
          "version": "1.1.0",
          "generatedAt": "2026-10-20T01:02:03Z",
          "base": {"tag": "v1.0.0", "sha": "aaa"},
          "head": {"ref": "origin/develop", "sha": "bbb"},
          "initial": false,
          "whatsNew": {"ja": "・起動時に落ちる不具合を直す\n・受信箱を絞り込めるようにする"},
          "omitted": 0,
          "pullRequests": [
            {"number": 2, "title": "起動時に落ちる不具合を直す", "type": "FIX", "url": "https://github.com/o/r/pull/2",
             "mergedAt": "2026-10-01T00:00:00Z", "epic": null, "included": true},
            {"number": 4, "title": "ワークフローを足す", "type": "CI", "url": "https://github.com/o/r/pull/4",
             "mergedAt": "2026-10-02T09:00:00+09:00", "epic": 7, "included": false},
            {"number": 5, "title": "種類の無いタイトル", "type": null, "url": "not a url", "mergedAt": "yesterday", "epic": null, "included": true}
          ],
          "messages": ["v1.0.0 から 3 件の PR を読みました。"]
        }
        """#

    @Test func decodesDraft() throws {
        let draft = try WhatsNewDraft.decode(Data(Self.draftJSON.utf8))
        #expect(draft.schemaVersion == 1)
        #expect(draft.version == "1.1.0")
        #expect(draft.generatedAt == Date(timeIntervalSince1970: 1_792_458_123))
        #expect(draft.base == .init(name: "v1.0.0", sha: "aaa"))
        #expect(draft.head == .init(name: "origin/develop", sha: "bbb"))
        #expect(!draft.initial)
        #expect(draft.whatsNew == ["ja": "・起動時に落ちる不具合を直す\n・受信箱を絞り込めるようにする"])
        #expect(draft.omitted == 0)
        #expect(draft.messages == ["v1.0.0 から 3 件の PR を読みました。"])
        #expect(draft.pullRequests.map(\.number) == [2, 4, 5])
        #expect(draft.pullRequests[0].type == "FIX")
        #expect(draft.pullRequests[0].url?.absoluteString == "https://github.com/o/r/pull/2")
        // git の %cI（オフセット付き）の日時も読む
        #expect(draft.pullRequests[1].mergedAt == Date(timeIntervalSince1970: 1_790_899_200))
        #expect(draft.pullRequests[1].epic == 7)
        #expect(!draft.pullRequests[1].included)
        // 表示にしか使わない URL・日時は、読めなくても下書きそのものは読む
        #expect(draft.pullRequests[2].type == nil)
        #expect(draft.pullRequests[2].mergedAt == nil)
    }

    @Test func decodesInitialDraftWithoutBase() throws {
        let json = #"""
            { "schemaVersion": 1, "version": "1.0.0", "generatedAt": "2026-10-20T01:02:03Z", "base": null,
              "head": {"ref": "origin/develop", "sha": "bbb"}, "initial": true, "whatsNew": {"ja": "はじめてのリリースです。"},
              "omitted": 0, "pullRequests": [], "messages": [] }
            """#
        let draft = try WhatsNewDraft.decode(Data(json.utf8))
        #expect(draft.base == nil)
        #expect(draft.initial)
        #expect(draft.pullRequests.isEmpty)
    }

    @Test func refusesUnknownSchemaVersionWithoutReadingTheRest() {
        // 版が違えばほかのキーの形が違っても読まずに知らせる
        let json = #"{ "schemaVersion": 2, "whatsNew": [1, 2, 3] }"#
        #expect(throws: ReleaseReadError.unsupportedDraftSchema(2)) {
            try WhatsNewDraft.decode(Data(json.utf8))
        }
    }

    @Test func reportsInvalidContent() {
        #expect(throws: ReleaseReadError.invalidContent(path: "AppStore/whats-new-draft.json")) {
            try WhatsNewDraft.decode(Data("not json".utf8))
        }
        #expect(throws: ReleaseReadError.invalidContent(path: "AppStore/whats-new-draft.json")) {
            try WhatsNewDraft.decode(Data(#"{ "schemaVersion": 1, "version": "1.1.0" }"#.utf8))
        }
    }
}

struct ReleaseNotesTests {
    private let version = ReleaseVersion(major: 1, minor: 1, patch: 0)

    @Test func confirmedOnlyWhenEveryLanguageHasTheReleaseVersion() {
        let current = ConfirmedWhatsNew(version: "1.1.0", text: "・直した")
        let previous = ConfirmedWhatsNew(version: "1.0.0", text: "・前のもの")
        #expect(ReleaseNotes.statusWithoutDraft(languages: ["ja"], whatsNew: ["ja": current], version: version) == .confirmed)
        #expect(ReleaseNotes.statusWithoutDraft(languages: ["ja", "en"], whatsNew: ["ja": current], version: version) == .missing)
        #expect(ReleaseNotes.statusWithoutDraft(languages: ["ja"], whatsNew: ["ja": previous], version: version) == .missing)
        #expect(ReleaseNotes.statusWithoutDraft(languages: [], whatsNew: [:], version: version) == .missing)

        let notes = ReleaseNotes(version: version, status: .missing, languages: ["ja", "en"], whatsNew: ["ja": current, "en": previous])
        #expect(notes.confirmedTexts == ["ja": "・直した"])
    }
}

struct ReleaseRefsTests {
    private static func ref(_ name: String) -> ReleaseRef {
        ReleaseRef(name: name, sha: "sha-\(name)", version: ReleaseVersion(branch: name) ?? ReleaseVersion(tag: name))
    }

    @Test func findsUnreleasedVersionsAndLatestTag() throws {
        let refs = ReleaseRefs(
            branches: ["release/1.0.0", "release/1.2.0", "release/1.1.0", "release/foo"].map(Self.ref),
            tags: ["v1.0.0", "v0.9.0", "very-old"].map(Self.ref)
        )
        #expect(refs.unreleasedVersions.map(\.description) == ["1.1.0", "1.2.0"])
        #expect(refs.latestTaggedVersion?.description == "1.0.0")
        let released = try #require(ReleaseVersion("1.0.0"))
        let preparing = try #require(ReleaseVersion("1.1.0"))
        let tagOnly = try #require(ReleaseVersion("0.9.0"))
        let fresh = try #require(ReleaseVersion("1.3.0"))
        #expect(refs.branch(for: preparing)?.sha == "sha-release/1.1.0")
        #expect(refs.tag(for: released)?.name == "v1.0.0")
        #expect(refs.isTaken(preparing))
        #expect(refs.isTaken(tagOnly))
        #expect(!refs.isTaken(fresh))
        #expect(ReleaseRefs(branches: [], tags: []).latestTaggedVersion == nil)
    }
}
