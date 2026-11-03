import XCTest

/// 新しい画面の主な流れ（デモのデータで動かす。GitHub にもトークンにも依存しない）
final class ClientUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 起動テスト（AskHubUITestsLaunchTests）は画面の向きを変えたまま残すことがあるので、縦向きに戻す
        #if os(iOS)
        MainActor.assumeIsolated {
            XCUIDevice.shared.orientation = .portrait
        }
        #endif
    }

    /// 一覧を下へ送りながら、要素が出るまで探す（一覧の行は画面に入るまで作られない）
    @MainActor
    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 4) -> Bool {
        for _ in 0..<maxSwipes where !element.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        return element.waitForExistence(timeout: 3)
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
        XCTAssertTrue(scrollUntilExists(app.staticTexts["時間のあるときに · 3"], in: app))
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

    /// 設定でデモの場面を変えると、その場面のデータを読み込み直す（作り直した store を読み込まないまま残さない）。
    /// 起動引数の `-demoScenario` は設定より優先されるので付けない。最後に標準の場面に戻す
    @MainActor
    func testChangingScenarioReloadsData() {
        let app = launch([])
        chooseScenario("人の出番が無い", in: app)
        XCTAssertTrue(app.staticTexts["あなたの番はありません"].waitForExistence(timeout: 10))
        chooseScenario("ひととおり（標準）", in: app)
        XCTAssertTrue(app.staticTexts["まとめて判断する"].waitForExistence(timeout: 10))
    }

    private func chooseScenario(_ label: String, in app: XCUIApplication) {
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        // メニューの選択は、名前に今の値が続いたボタンになる（例「デモの場面, ひととおり（標準）」）
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "デモの場面")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        picker.tap()
        app.buttons[label].firstMatch.tap()
        app.buttons["閉じる"].firstMatch.tap()
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

    #if os(iOS)
    /// 自由記述のカードでは、キーボードの上の「完了」と、入力欄より上を叩くことでキーボードを閉じられる
    @MainActor
    func testFreeTextCardClosesKeyboard() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"], reactionDelay: 600)
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        // Q2 に答えて、自由記述の Q3 を前に出す
        card.buttons["共有シートだけ（左下へスワイプ）"].tap()
        let title = card.staticTexts["ファイル名の決まり"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let field = card.descendants(matching: .any)["deckCard.freeText"]
        let keyboard = app.keyboards.firstMatch

        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))

        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }
    #endif

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
        XCTAssertTrue(app.staticTexts["習慣ログ"].waitForExistence(timeout: 5))
    }
}
