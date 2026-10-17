@testable import AskHubKit
import Testing

struct ThirdPartyReviewMarkerTests {
    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func parsesShaAndCounts() {
        let body = """
        <!-- ralph:third-party-review sha="\(Self.sha)" must="1" may="2" -->
        ## 🔍 コードレビュー（第三者）: ❌ 修正が必要（要修正 1 件・提案 2 件）
        """
        let marker = ThirdPartyReviewMarker.parse(body)
        #expect(marker == ThirdPartyReviewMarker(sha: Self.sha, must: 1, may: 2))
        #expect(marker?.isClean == false)
    }

    @Test func mustZeroIsClean() {
        let marker = ThirdPartyReviewMarker.parse(#"<!-- ralph:third-party-review sha="abc1234" must="0" may="3" -->"#)
        #expect(marker == ThirdPartyReviewMarker(sha: "abc1234", must: 0, may: 3))
        #expect(marker?.isClean == true)
    }

    @Test func mayDefaultsToZeroAndShaIsLowercased() {
        let marker = ThirdPartyReviewMarker.parse("\r\n  <!--ralph:third-party-review   must=\"0\" sha=\"ABCDEF1\"-->\n本文")
        #expect(marker == ThirdPartyReviewMarker(sha: "abcdef1", must: 0, may: 0))
    }

    @Test(arguments: [
        "",
        "レビューではないコメント",
        // 以前の書式（件数が無い）はマージの判定に使えない
        #"<!-- ralph:third-party-review sha="abc1234" -->"#,
        #"<!-- ralph:third-party-review must="0" may="0" -->"#,
        #"<!-- ralph:third-party-review sha="" must="0" -->"#,
        #"<!-- ralph:third-party-review sha="abc" must="0" -->"#,
        #"<!-- ralph:third-party-review sha="xyz1234" must="0" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must="-1" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must="+1" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must=" 1" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must="１" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must="0" may="many" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must="99999999999999999999" -->"#,
        #"<!-- ralph:third-party-reviewer sha="abc1234" must="0" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234" must=0 -->"#,
        #"前置き <!-- ralph:third-party-review sha="abc1234" must="0" -->"#
    ])
    func rejectsMalformedMarkers(body: String) {
        #expect(ThirdPartyReviewMarker.parse(body) == nil)
    }

    @Test func htmlCommentRoundTrips() throws {
        let marker = ThirdPartyReviewMarker(sha: Self.sha, must: 2, may: 0)
        let comment = try #require(marker.htmlComment)
        #expect(comment == #"<!-- ralph:third-party-review sha="\#(Self.sha)" must="2" may="0" -->"#)
        #expect(ThirdPartyReviewMarker.parse(comment) == marker)
    }

    @Test func htmlCommentRejectsUnrepresentableValues() {
        #expect(ThirdPartyReviewMarker(sha: #"abc1234" must="0"#, must: 1, may: 0).htmlComment == nil)
        #expect(ThirdPartyReviewMarker(sha: Self.sha, must: -1, may: 0).htmlComment == nil)
        #expect(ThirdPartyReviewMarker(sha: Self.sha, must: 0, may: -1).htmlComment == nil)
    }
}
