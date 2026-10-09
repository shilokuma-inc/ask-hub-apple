@testable import AskHubKit
import Testing

struct VerifyMarkerTests {
    @Test func roundTripsWithBothFields() {
        let marker = VerifyMarker(pullRequest: 123, epic: "epic/verify-tab-ui")
        let parsed = VerifyMarker.parse(marker.marker)
        #expect(parsed == marker)
    }

    @Test func roundTripsWithPullRequestOnly() {
        let marker = VerifyMarker(pullRequest: 456)
        #expect(VerifyMarker.parse(marker.marker) == marker)
    }

    @Test func roundTripsWithEpicOnly() {
        let marker = VerifyMarker(epic: "epic/xxx")
        #expect(VerifyMarker.parse(marker.marker) == marker)
    }

    @Test func roundTripsWithNoFields() {
        let marker = VerifyMarker()
        #expect(VerifyMarker.parse(marker.marker) == marker)
    }

    @Test func parsesFromIssueBodyWithLeadingWhitespace() {
        let body = "\n\n<!-- ask-hub:verify {\"epic\":\"epic/foo\"} -->\n本文の続き"
        let parsed = VerifyMarker.parse(body)
        #expect(parsed?.epic == "epic/foo")
        #expect(parsed?.pullRequest == nil)
    }

    @Test func parsesBodyWithHumanReadableTableAfterMarker() {
        let body = """
        <!-- ask-hub:verify {"pullRequest":99,"epic":"epic/bar"} -->
        ## 確認手順
        ...
        """
        let parsed = VerifyMarker.parse(body)
        #expect(parsed?.pullRequest == 99)
        #expect(parsed?.epic == "epic/bar")
    }

    @Test func ignoresUnknownKeys() {
        let body = #"<!-- ask-hub:verify {"pullRequest":1,"unknownKey":"ignored","epic":"e"} -->"#
        let parsed = VerifyMarker.parse(body)
        #expect(parsed?.pullRequest == 1)
        #expect(parsed?.epic == "e")
    }

    @Test func returnsNilWhenMarkerIsAbsent() {
        #expect(VerifyMarker.parse("本文だけ") == nil)
    }

    @Test func returnsNilWhenDifferentKeyword() {
        let body = #"<!-- ask-hub:verifier {"pullRequest":1} -->"#
        #expect(VerifyMarker.parse(body) == nil)
    }

    @Test func returnsNilWhenMarkerIsNotAtStart() {
        let body = "前置きテキスト\n<!-- ask-hub:verify {\"pullRequest\":1} -->"
        #expect(VerifyMarker.parse(body) == nil)
    }

    @Test func escapesGreaterThanInMarker() {
        // JSON の文字列に `>` があっても `-->` と取り違えない
        let marker = VerifyMarker(epic: "epic/a\u{003e}b")
        let content = marker.marker
        #expect(content.contains("\\u003e"))
        // 末尾の ` -->` を除いた部分（JSON 本体）に生の `>` が無いこと
        let withoutClose = String(content.dropLast(4)) // drop " -->"
        #expect(!withoutClose.contains(">"))
    }

    @Test func markerHasExpectedPrefix() {
        let marker = VerifyMarker(pullRequest: 1, epic: "epic/x")
        #expect(marker.marker.hasPrefix("<!-- ask-hub:verify {"))
        #expect(marker.marker.hasSuffix(" -->"))
    }
}
