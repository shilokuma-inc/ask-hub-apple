import XCTest

// MARK: - 実機確認の一覧

extension ClientUITests {
    /// 実機確認の一覧から、epic ごとにまとめて答える。行をスワイプして「まとめて確認した」を押すと、取り消しの猶予つきで送り、行がすぐ消える。
    /// 「確かめずに閉じる…」は理由のシートを出し、空のままでも送れる。確かめるものが無くなっても、配信した版の確認は畳んだまま残る
    @MainActor
    func testVerificationListAnswersEpicsInBulk() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "verifications"])
        XCTAssertTrue(app.staticTexts["実機で確かめるもの · 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["まとめてスワイプで答える"].exists)

        row("ウィジェットに降り始めの時刻を出す", in: app).swipeLeft()
        let confirm = app.buttons["まとめて確認した"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["取り消す"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["実機で確かめるもの · 1"].waitForExistence(timeout: 5))

        row("週の振り返り画面", in: app).swipeLeft()
        let close = app.buttons["確かめずに閉じる…"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let send = app.buttons["送る"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["空のままでも送れます"].exists)
        send.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["配信した版の確認 · 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["まとめてスワイプで答える"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 実機確認の一覧の epic の行（アプリ・題・残りの数を 1 つに読む）
    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), title)
        return row
    }
}
