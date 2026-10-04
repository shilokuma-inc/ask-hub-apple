@testable import AskHubKit
import Testing

struct QuestionMarkerTests {
    @Test func parsesIdAndOptions() {
        let body = """
        <!-- ask-hub:question id="d12-q3" options="24時間|1時間|送信1回分" -->
        ### Q3. レート制限の単位
        """
        #expect(QuestionMarker.parse(body) == QuestionMarker(id: "d12-q3", options: ["24時間", "1時間", "送信1回分"]))
    }

    @Test func optionsAreOptional() {
        let marker = QuestionMarker.parse(#"<!-- ask-hub:question id="pr34-1" -->"#)
        #expect(marker == QuestionMarker(id: "pr34-1"))
        #expect(marker?.isFreeForm == true)
    }

    @Test func attributeOrderDoesNotMatter() {
        let marker = QuestionMarker.parse(#"<!-- ask-hub:question options="A|B" id="q1" -->"#)
        #expect(marker == QuestionMarker(id: "q1", options: ["A", "B"]))
    }

    @Test func ignoresSurroundingWhitespaceAndEmptyOptions() {
        let marker = QuestionMarker.parse("\r\n  <!--ask-hub:question   id=\"q1\" options=\" A | |B \"-->\r\n本文")
        #expect(marker == QuestionMarker(id: "q1", options: ["A", "B"]))
    }

    @Test func requiresMarkerAtTheBeginning() {
        #expect(QuestionMarker.parse(#"前置き <!-- ask-hub:question id="q1" -->"#) == nil)
        #expect(QuestionMarker.parse(#"<!-- note --><!-- ask-hub:question id="q1" -->"#) == nil)
    }

    @Test(arguments: [
        "",
        "質問ではないコメント",
        #"<!-- ask-hub:question -->"#,
        #"<!-- ask-hub:question id="" -->"#,
        #"<!-- ask-hub:question options="A|B" -->"#,
        #"<!-- ask-hub:questionnaire id="q1" -->"#,
        #"<!-- ask-hub:question id="q1" options=A|B -->"#,
        #"<!-- ask-hub:question id="q1""#
    ])
    func rejectsMalformedMarkers(body: String) {
        #expect(QuestionMarker.parse(body) == nil)
    }

    @Test func firstDuplicateAttributeWins() {
        #expect(QuestionMarker.parse(#"<!-- ask-hub:question id="a" id="b" -->"#)?.id == "a")
    }

    @Test func htmlCommentRoundTrips() {
        let markers = [
            QuestionMarker(id: "d1-q1", options: ["はい", "いいえ"]),
            QuestionMarker(id: "pr2-1")
        ]
        for marker in markers {
            #expect(QuestionMarker.parse(marker.htmlComment) == marker)
        }
        #expect(markers[1].htmlComment == #"<!-- ask-hub:question id="pr2-1" -->"#)
    }
}
