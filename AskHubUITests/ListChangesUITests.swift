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

        // ループが 3 つ回っているリポジトリ（見出し + ループの 3 行）を、Q1 と同じスワイプの「担当から外す」で外す。依頼はデモの取得元に送り、GitHub には送らない
        app.tabBars.buttons["ステータス"].tap()
        let heading = app.staticTexts["pair-quiz-ios"]
        scrollToRow(heading, in: app)
        XCTAssertTrue(app.staticTexts["ループ 3 つ"].exists)
        removeBySwipe(heading, in: app)

        // 引っぱって更新するたびに一覧の中身が変わる。外したリポジトリは見出しとループの行が消え、「担当 PC なし」の 1 行になる
        for _ in 0..<4 {
            pullDownToRefresh(in: app)
        }
        scrollToRow(app.staticTexts["pair-quiz-ios"], in: app)
        XCTAssertFalse(app.staticTexts["ループ 3 つ"].exists)
        XCTAssertTrue(unassignedText(of: "pair-quiz-ios", in: app).exists)

        // ほかのタブの一覧も、更新のたびに要素の増減・並びの入れ替え・重複が起きる
        for tab in ["要対応", "任意判断", "実機確認", "ステータス"] {
            app.tabBars.buttons[tab].tap()
            for _ in 0..<3 {
                pullDownToRefresh(in: app)
            }
        }
    }

    /// ループが 1 つの（1 行で出る）リポジトリも、スワイプで外した後の更新で落ちない
    @MainActor
    func testSwipeRemovingSingleRowRepositoryKeepsRunning() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox", "-AskHubSampleChanges"]
        app.launch()

        app.tabBars.buttons["ステータス"].tap()
        let row = app.staticTexts["lingo-cards"]
        scrollToRow(row, in: app)
        removeBySwipe(row, in: app)

        for _ in 0..<3 {
            pullDownToRefresh(in: app)
        }
        scrollToRow(app.staticTexts["lingo-cards"], in: app)
        XCTAssertTrue(unassignedText(of: "lingo-cards", in: app).exists)
    }

    /// 行をスワイプして「担当から外す」を押し、依頼を送ってシートを閉じる。押した直後に落ちていないことも確かめる
    @MainActor
    private func removeBySwipe(_ row: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        row.swipeLeft()
        let remove = app.buttons["担当から外す"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), file: file, line: line)
        remove.tap()
        let send = app.buttons["send-removal"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "押した後にシートが出ない（落ちた）", file: file, line: line)
        send.tap()
        let close = app.buttons["閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        close.tap()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 2), "シートを閉じた後にアプリが落ちた", file: file, line: line)
    }

    /// リポジトリの行の「担当 PC なし」（外した後に、オーケストレーターが担当の印を消した状態）
    @MainActor
    private func unassignedText(of repository: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: repository).staticTexts["担当 PC なし"].firstMatch
    }

    /// 一覧の先頭に戻してから引っぱって更新し、更新の差分が当たるまで待ってアプリが落ちていないことを確かめる
    @MainActor
    private func pullDownToRefresh(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), file: file, line: line)
        list.swipeDown(velocity: .fast)
        list.swipeDown(velocity: .fast)
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        top.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        // 落ちるとアプリが終わる。サンプルの取得はすぐ返るので、2 秒待てば差分は当たり終わっている
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 2), "更新の後にアプリが落ちた", file: file, line: line)
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
