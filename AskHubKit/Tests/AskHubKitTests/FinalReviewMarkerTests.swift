@testable import AskHubKit
import Testing

struct FinalReviewMarkerTests {
    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func parsesStateShaAndAttempts() {
        let body = """
        <!-- ask-hub:final-review state="fixing" sha="\(Self.sha)" attempts="2" -->
        第三者レビューの要修正を直しています
        """
        #expect(FinalReviewMarker.parse(body) == FinalReviewMarker(state: .fixing, sha: Self.sha, attempts: 2))
    }

    @Test(arguments: [
        ("waiting", FinalReviewMarker.State.waiting),
        ("reviewing", .reviewing),
        ("fixing", .fixing),
        ("done", .done),
        ("done-coderabbit", .doneCodeRabbit),
        ("gave-up", .gaveUp)
    ])
    func parsesEveryState(raw: String, state: FinalReviewMarker.State) {
        let sha = "abc1234abc1234abc1234abc1234abc1234abc12"
        let marker = FinalReviewMarker.parse(#"<!-- ask-hub:final-review state="\#(raw)" sha="\#(sha)" -->"#)
        #expect(marker == FinalReviewMarker(state: state, sha: "abc1234abc1234abc1234abc1234abc1234abc12", attempts: 0))
    }

    @Test(arguments: [
        "",
        #"<!-- ask-hub:final-review sha="abc1234abc1234abc1234abc1234abc1234abc12" -->"#,
        #"<!-- ask-hub:final-review state="unknown" sha="abc1234abc1234abc1234abc1234abc1234abc12" -->"#,
        #"<!-- ask-hub:final-review state="Done" sha="abc1234abc1234abc1234abc1234abc1234abc12" -->"#,
        #"<!-- ask-hub:final-review state="done" -->"#,
        #"<!-- ask-hub:final-review state="done" sha="not-a-sha" -->"#,
        #"<!-- ask-hub:final-review state="done" sha="abc1234" -->"#,
        #"<!-- ask-hub:final-review state="done" sha="abc1234abc1234abc1234abc1234abc1234abc12" attempts="x" -->"#,
        #"<!-- ask-hub:final-reviews state="done" sha="abc1234abc1234abc1234abc1234abc1234abc12" -->"#,
        #"<!-- ralph:third-party-review sha="abc1234abc1234abc1234abc1234abc1234abc12" must="0" may="0" -->"#,
        #"前置き <!-- ask-hub:final-review state="done" sha="abc1234abc1234abc1234abc1234abc1234abc12" -->"#
    ])
    func rejectsMalformedMarkers(body: String) {
        #expect(FinalReviewMarker.parse(body) == nil)
    }

    @Test func htmlCommentRoundTripsEveryState() throws {
        for state in FinalReviewMarker.State.allCases {
            let marker = FinalReviewMarker(state: state, sha: Self.sha, attempts: 3)
            let comment = try #require(marker.htmlComment)
            #expect(FinalReviewMarker.parse(comment) == marker)
        }
    }

    @Test func initLowercasesSha() {
        #expect(FinalReviewMarker(state: .waiting, sha: Self.sha.uppercased()).sha == Self.sha)
    }

    @Test func htmlCommentRejectsUnrepresentableValues() {
        #expect(FinalReviewMarker(state: .done, sha: "", attempts: 0).htmlComment == nil)
        #expect(FinalReviewMarker(state: .done, sha: Self.sha, attempts: -1).htmlComment == nil)
    }

    @Test func describesProgress() {
        func text(_ state: FinalReviewMarker.State, attempts: Int = 0) -> String {
            FinalReviewMarker(state: state, sha: Self.sha, attempts: attempts).progressText
        }
        #expect(text(.waiting) == "CodeRabbit を待っています")
        #expect(text(.reviewing) == "レビュー中")
        #expect(text(.fixing) == "修正中")
        #expect(text(.fixing, attempts: 2) == "修正中（2 回目）")
        #expect(text(.done) == "済み")
        #expect(text(.doneCodeRabbit) == "済み（CodeRabbit）")
        #expect(text(.gaveUp, attempts: 3) == "あきらめました（要修正が 3 回続きました）")
        // 回数が無い（コマンドの失敗であきらめた・attempts を省いた目印）ときは回数を出さない
        #expect(text(.gaveUp) == "あきらめました")
    }
}
