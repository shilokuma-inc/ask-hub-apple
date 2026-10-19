import XCTest

// 任意判断・実機確認の一覧の、リポジトリでの絞り込みと作成日・更新日の並び替え（Discussion #586）
extension AskHubUITests {
    private enum VerifyRow {
        static let pat = "PAT の Keychain への保存と macOS の設定画面の見た目"
        static let ipad = "iPad での受信箱の 2 列表示"
        static let notification = "通知の許可ダイアログと届いた通知の表示"
        static let practice = "練習モードの音とタップのずれ"
        static let fork = "個人のフォークでのメトロノームの音量"
    }

    @MainActor
    private func openFilterMenu(_ app: XCUIApplication) {
        let menu = app.buttons["絞り込みと並び替え"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
    }

    @MainActor
    private func assertAbove(_ upper: XCUIElement, _ lower: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, file: file, line: line)
    }

    @MainActor
    func testFilterVerificationListByRepository() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["実機確認"].tap()
        XCTAssertTrue(app.staticTexts[VerifyRow.pat].waitForExistence(timeout: 5))

        // 候補はこのタブのリポジトリと件数。別の owner の同じ名前のリポジトリは owner/repo で見分ける
        openFilterMenu(app)
        XCTAssertTrue(app.buttons["すべて（5）"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notti-ios（1）"].exists)
        XCTAssertTrue(app.buttons["mrs1669/beat-tap-ios（1）"].exists)
        XCTAssertTrue(app.buttons["shilokuma-inc/beat-tap-ios（1）"].exists)
        let askHub = app.buttons["ask-hub-apple（2）"]
        XCTAssertTrue(askHub.exists)
        askHub.tap()

        // 選んだリポジトリの Issue だけを出す
        XCTAssertTrue(app.staticTexts[VerifyRow.pat].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[VerifyRow.ipad].exists)
        XCTAssertFalse(app.staticTexts[VerifyRow.notification].exists)
        XCTAssertFalse(app.staticTexts[VerifyRow.practice].exists)
        XCTAssertFalse(app.staticTexts[VerifyRow.fork].exists)

        // 絞り込みはタブごと。任意判断には持ち込まない
        app.tabBars.buttons["任意判断"].tap()
        XCTAssertTrue(app.staticTexts["epic/notification の仮決め一覧"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["epic/practice-mode の仮決め一覧"].exists)

        // 実機確認に戻っても絞り込んだまま。「すべて」で元に戻る
        app.tabBars.buttons["実機確認"].tap()
        XCTAssertTrue(app.staticTexts[VerifyRow.ipad].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[VerifyRow.notification].exists)
        openFilterMenu(app)
        let all = app.buttons["すべて（5）"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(app.staticTexts[VerifyRow.notification].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[VerifyRow.fork].exists)
    }

    @MainActor
    func testSortDecisionAndVerificationLists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 既定は更新日（新しい順）
        app.tabBars.buttons["実機確認"].tap()
        let pat = app.staticTexts[VerifyRow.pat]
        let notification = app.staticTexts[VerifyRow.notification]
        let ipad = app.staticTexts[VerifyRow.ipad]
        XCTAssertTrue(pat.waitForExistence(timeout: 5))
        assertAbove(pat, notification)
        assertAbove(notification, ipad)

        // 作成日（古い順）では、作成の古い iPad（20 日前）・通知（16 日前）・PAT（5 日前）の順になる
        openFilterMenu(app)
        let createdOldest = app.buttons["作成日（古い順）"]
        XCTAssertTrue(createdOldest.waitForExistence(timeout: 5))
        createdOldest.tap()
        XCTAssertTrue(ipad.waitForExistence(timeout: 5))
        assertAbove(ipad, notification)
        assertAbove(notification, pat)

        // 任意判断の並びは既定のまま（並び替えもタブごと）。作成日（新しい順）にすると順が変わる
        app.tabBars.buttons["任意判断"].tap()
        let mvp = app.staticTexts["epic/mvp の仮決め一覧"]
        let practice = app.staticTexts["epic/practice-mode の仮決め一覧"]
        let settings = app.staticTexts["epic/settings-ui の仮決め一覧"]
        XCTAssertTrue(mvp.waitForExistence(timeout: 5))
        assertAbove(mvp, practice)
        assertAbove(practice, settings)
        openFilterMenu(app)
        let createdNewest = app.buttons["作成日（新しい順）"]
        XCTAssertTrue(createdNewest.waitForExistence(timeout: 5))
        createdNewest.tap()
        XCTAssertTrue(practice.waitForExistence(timeout: 5))
        assertAbove(practice, mvp)
        assertAbove(mvp, settings)
    }

    @MainActor
    func testFilterFallsBackToAllWhenRepositoryIsGone() throws {
        let app = XCUIApplication()
        // サンプルデータでは閉じたことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["実機確認"].tap()
        XCTAssertTrue(app.staticTexts[VerifyRow.pat].waitForExistence(timeout: 5))
        openFilterMenu(app)
        let fork = app.buttons["mrs1669/beat-tap-ios（1）"]
        XCTAssertTrue(fork.waitForExistence(timeout: 5))
        fork.tap()
        let row = app.staticTexts[VerifyRow.fork]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[VerifyRow.pat].exists)

        // そのリポジトリの唯一の Issue を閉じると、一覧から消えるので「すべて」に戻る
        row.tap()
        let close = app.buttons["確認済みとして閉じる"]
        XCTAssertTrue(app.staticTexts["確認手順"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !close.exists {
            app.swipeUp()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let confirm = app.buttons["閉じる"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["実機確認"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[VerifyRow.pat].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[VerifyRow.notification].exists)
        XCTAssertFalse(app.staticTexts["このリポジトリの実機確認はありません"].exists)
        XCTAssertFalse(app.staticTexts[VerifyRow.fork].exists)
    }
}
