import XCTest

// 一覧の中身が更新のたびに変わっても落ちないこと（Discussion #743。TestFlight の iOS 27.0 で、ステータスタブの「担当から外す」の後に
// List の差分の適用で落ちた）。差分を当てるのは iOS の UICollectionView なので、iOS だけで流す
#if os(iOS)
extension AskHubUITests {
    @MainActor
    func testListsKeepRunningWhileContentsChangeAfterRemovingRepository() throws {
        let app = XCUIApplication()
        // サンプルの取得元が、更新のたびに違う中身（要素の増減・並びの入れ替え・重複・ループの数の変化）を返す
        app.launchArguments += ["-AskHubSampleInbox", "-AskHubSampleChanges"]
        app.launch()

        // ループが 3 つ回っているリポジトリ（見出し + ループの 3 行）を担当から外す。依頼はデモの取得元に送り、GitHub には送らない
        app.tabBars.buttons["ステータス"].tap()
        let heading = app.staticTexts["pair-quiz-ios"]
        scrollToRow(heading, in: app)
        XCTAssertTrue(app.staticTexts["ループ 3 つ"].exists)
        // コンテキストメニューから開く（スワイプの「担当から外す」は、押した直後に List の行の数が合わずに落ちることが分かっている。直し方は判断待ち）
        heading.press(forDuration: 1.2)
        let remove = app.buttons["担当から外す"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let send = app.buttons["send-removal"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.tap()
        let close = app.buttons["閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        // 引っぱって更新するたびに一覧の中身が変わる。外したリポジトリは見出しとループの行が消え、「担当 PC なし」の 1 行になる
        for _ in 0..<4 {
            pullDownToRefresh(in: app)
        }
        scrollToRow(app.staticTexts["pair-quiz-ios"], in: app)
        XCTAssertFalse(app.staticTexts["ループ 3 つ"].exists)

        // ほかのタブの一覧も、更新のたびに要素の増減・並びの入れ替え・重複が起きる
        for tab in ["要対応", "任意判断", "実機確認", "ステータス"] {
            app.tabBars.buttons[tab].tap()
            for _ in 0..<3 {
                pullDownToRefresh(in: app)
            }
        }
    }

    /// 一覧の先頭に戻してから引っぱって更新し、アプリが落ちていないことを確かめる
    @MainActor
    private func pullDownToRefresh(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), file: file, line: line)
        list.swipeDown(velocity: .fast)
        list.swipeDown(velocity: .fast)
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        top.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertEqual(app.state, .runningForeground, "更新の後にアプリが落ちた", file: file, line: line)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
    }

    /// 行が画面に出るまで、一覧の先頭からゆっくり上にスクロールする（画面の外の行は作られない。ステータスタブは長いので `scrollToHittable` より多く送る）
    @MainActor
    private func scrollToRow(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), file: file, line: line)
        list.swipeDown(velocity: .fast)
        for _ in 0..<12 {
            if element.exists && element.isHittable {
                return
            }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) が画面に出ない", file: file, line: line)
    }
}
#endif
