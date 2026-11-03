import XCTest

/// 新しい画面の主な流れ（デモのデータで動かす。GitHub にもトークンにも依存しない）
final class ClientUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// デモの場面で起動する。機械の反応は既定ではすぐ起こす
    @MainActor
    private func launch(_ arguments: [String], reactionDelay: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoReactionDelay", "\(reactionDelay)", "-swipeHand", "right"] + arguments
        app.launch()
        return app
    }

    /// あなたの番に、進行を止めているものとまとめて判断する入口が出る
    @MainActor
    func testInboxShowsBlockingItems() {
        let app = launch(["-demoScenario", "standard"])
        XCTAssertTrue(app.staticTexts["進行が止まっています · 6"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["まとめて判断する"].exists)
        // 「時間のあるときに」は下にあるので、一覧を送ってから確かめる
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(app.staticTexts["時間のあるときに · 3"].waitForExistence(timeout: 5))
    }

    /// 読めなかったときは「ありません」と出さない
    @MainActor
    func testFailureIsNotShownAsEmpty() {
        let app = launch(["-demoScenario", "failing"])
        XCTAssertTrue(app.staticTexts["読み込めませんでした"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["あなたの番はありません"].exists)
        XCTAssertTrue(app.buttons["もう一度読む"].exists)
    }

    /// 人の出番が無いときは、機械が何件を進めているかを出す
    @MainActor
    func testQuietScenarioShowsEmptyState() {
        let app = launch(["-demoScenario", "quiet"])
        XCTAssertTrue(app.staticTexts["あなたの番はありません"].waitForExistence(timeout: 10))
    }

    /// カードを右上へスワイプすると推奨で答え、猶予の間は取り消せる
    @MainActor
    func testSwipeAnswersAndCanUndo() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.staticTexts["書き出したファイルの置き場所"].exists)

        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 240, dy: -240)))

        let undo = app.buttons["取り消す"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["習慣ログ · 質問 Q2 / 4: ファイル App に保存"].exists)
        undo.tap()
        XCTAssertTrue(card.staticTexts["書き出したファイルの置き場所"].waitForExistence(timeout: 5))
    }

    /// まとめて判断するでは、前のカードを飛ばすと後ろのカードが前に出て、続けて答えられる
    @MainActor
    func testSwipeThroughDeck() {
        // 答えに反応して新しいカード（ロックが外れた質問）が割り込まないよう、機械の反応を遅くする
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:all"], reactionDelay: 600)
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let titles = ["まとめを届ける曜日と時刻", "書き出したファイルの置き場所", "ファイル名の決まり"]
        // ↗（推奨）と ↙ に続けて飛ばす
        let moves = [CGVector(dx: 240, dy: -240), CGVector(dx: -240, dy: 240)]
        for (index, move) in moves.enumerated() {
            XCTAssertTrue(card.staticTexts[titles[index]].waitForExistence(timeout: 5))
            let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(move))
        }
        XCTAssertTrue(card.staticTexts[titles[2]].waitForExistence(timeout: 5))
    }

    /// 選択肢を押しても答えられる（スワイプの代わり）
    @MainActor
    func testTapChoiceAnswers() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.buttons["共有シートだけ（左下へスワイプ）"].tap()
        XCTAssertTrue(app.staticTexts["習慣ログ · 質問 Q2 / 4: 共有シートだけ"].waitForExistence(timeout: 5))
    }

    /// 進行中・Mac・リポジトリのタブを開ける
    @MainActor
    func testTabsOpen() {
        let app = launch(["-demoScenario", "standard"])
        XCTAssertTrue(app.tabBars.buttons["進行中"].waitForExistence(timeout: 10))
        app.tabBars.buttons["進行中"].tap()
        XCTAssertTrue(app.staticTexts["あなた待ち · 5"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Mac"].tap()
        XCTAssertTrue(app.staticTexts["Mac mini"].waitForExistence(timeout: 5))
        app.tabBars.buttons["リポジトリ"].tap()
        XCTAssertTrue(app.staticTexts["積読リスト"].waitForExistence(timeout: 5))
    }
}
