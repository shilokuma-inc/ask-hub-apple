@testable import AskHubKit
import Testing

/// 本文の先頭の HTML コメントの読み方。public のリポジトリでは誰でも本文を書けるので、崩れた本文でも落ちずに `nil` を返す
struct MarkerCommentTests {
    /// 開きと閉じが重なる・中身が空・閉じが無い本文。どの目印としても読めない
    static let bodiesWithoutMarker = [
        "<!-->",
        "<!--->",
        "\n  <!-->本文",
        "<!--> -->",
        "<!---> -->",
        "<!-- -->",
        "<!---->",
        "<!--",
        "<!-- 閉じていないコメント"
    ]

    /// `bodiesWithoutMarker` に、目印の語を含むが開きと閉じが重なる・閉じが無い本文を足したもの
    static func bodies(keyword: String) -> [String] {
        bodiesWithoutMarker + [
            "<!--> \(keyword) -->",
            "<!---> \(keyword) {} -->",
            "<!-- \(keyword) {}"
        ]
    }

    @Test func leadingCommentContentIsBetweenOpenAndClose() {
        #expect(MarkerComment.leadingCommentContent("\n <!--  ask-hub:x a=\"1\"\n-->本文 -->") == #"ask-hub:x a="1""#)
        #expect(MarkerComment.leadingCommentContent("<!-- -->")?.isEmpty == true)
        #expect(MarkerComment.leadingCommentContent("<!---->")?.isEmpty == true)
    }

    /// 閉じは開きの後ろから探す（`<!-->` の開きと重なる `-->` を閉じとみなさない）
    @Test func leadingCommentCloseMustFollowOpen() {
        #expect(MarkerComment.leadingCommentContent("<!-->") == nil)
        #expect(MarkerComment.leadingCommentContent("<!--->") == nil)
        #expect(MarkerComment.leadingCommentContent("<!-->本文 -->") == ">本文")
        #expect(MarkerComment.leadingCommentContent("<!---> -->") == "->")
    }

    @Test func leadingCommentRequiresClosedCommentAtTheBeginning() {
        #expect(MarkerComment.leadingCommentContent("") == nil)
        #expect(MarkerComment.leadingCommentContent("<!--") == nil)
        #expect(MarkerComment.leadingCommentContent("<!-- 閉じていない") == nil)
        #expect(MarkerComment.leadingCommentContent("前置き <!-- x -->") == nil)
    }

    @Test(arguments: bodies(keyword: QuestionMarker.keyword))
    func questionMarkerIsNil(_ body: String) {
        #expect(MarkerComment.attributes(body, keyword: QuestionMarker.keyword) == nil)
        #expect(QuestionMarker.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: ThirdPartyReviewMarker.keyword))
    func thirdPartyReviewMarkerIsNil(_ body: String) {
        #expect(ThirdPartyReviewMarker.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: FinalReviewMarker.keyword))
    func finalReviewMarkerIsNil(_ body: String) {
        #expect(FinalReviewMarker.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: CIFixMarker.keyword))
    func ciFixMarkerIsNil(_ body: String) {
        #expect(CIFixMarker.parse(body) == nil)
        #expect(CIFixMarker.parse(FinalPullRequestMarker.orchestrator + "\n" + body) == nil)
    }

    @Test(arguments: bodies(keyword: "ask-hub:verify"))
    func verifyMarkerIsNil(_ body: String) {
        #expect(VerifyMarker.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: "ask-hub:loop-status"))
    func loopStatusReportIsNil(_ body: String) {
        #expect(LoopStatusReport.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: "ask-hub:repository-status"))
    func repositoryStatusReportIsNil(_ body: String) {
        #expect(RepositoryStatusReport.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: "ask-hub:build-hosts"))
    func buildHostsReportIsNil(_ body: String) {
        #expect(BuildHostsReport.parse(body) == nil)
    }

    @Test(arguments: bodies(keyword: RepositoryRequest.keyword))
    func repositoryRequestIsNil(_ body: String) {
        #expect(RepositoryRequest.parse(body) == nil)
    }

    /// 開きに目印の語まで含めて探すので、閉じと重ならない（念のため確かめる）
    @Test(arguments: bodies(keyword: LoopOptions.keyword))
    func loopOptionsIsNil(_ body: String) {
        #expect(LoopOptions.parse(body) == nil)
    }
}
