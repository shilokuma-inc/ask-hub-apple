import XCTest

// タブの分け方（任意判断と実機確認）
extension AskHubUITests {
    @MainActor
    func testDecisionAndVerificationTabsAreSeparated() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 任意判断には仮決め一覧だけを出す。タイトルの先頭の【CHORE】は表示で省く
        app.tabBars.buttons["任意判断"].tap()
        XCTAssertTrue(app.staticTexts["epic/mvp の仮決め一覧"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["epic/notification の仮決め一覧"].exists)
        XCTAssertFalse(app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"].exists)

        // 実機確認は別のタブ。タイトルの先頭の「【CHORE】実機確認: 」は表示で省く
        app.tabBars.buttons["実機確認"].tap()
        XCTAssertTrue(app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["epic/mvp の仮決め一覧"].exists)
        // 元の PR 番号は本文の目印からだけ出す（目印の無い notti-ios#52 の本文の「元の PR: #41」は拾わない）
        XCTAssertTrue(app.staticTexts["元の PR #17"].exists)
        XCTAssertFalse(app.staticTexts["元の PR #41"].exists)
    }
}

// 任意判断・実機確認の詳細画面（Discussion #331）
extension AskHubUITests {
    @MainActor
    func testOpenIssueDetailFromDecisionAndVerificationTabs() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 実機確認の行を開くと、本文の見出しが Markdown の記号なしで出る
        app.tabBars.buttons["実機確認"].tap()
        let verification = app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"]
        XCTAssertTrue(verification.waitForExistence(timeout: 5))
        verification.tap()
        XCTAssertTrue(app.staticTexts["確認手順"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["期待する結果"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "## ")).firstMatch.exists)
        // 本文の先頭の目印は本文には出さず、元の PR 番号と epic として出す（LabeledContent は「名前, 値」の 1 つの要素になる）
        XCTAssertTrue(app.staticTexts["元の PR, #17"].exists)
        XCTAssertTrue(app.staticTexts["epic, epic/mvp"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ask-hub:verify")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["GitHub で開く"].exists)
        let verificationScreenshot = XCTAttachment(screenshot: app.screenshot())
        verificationScreenshot.name = "issue-detail-verification"
        verificationScreenshot.lifetime = .keepAlways
        add(verificationScreenshot)

        // 仮決め一覧も同じ詳細画面で、本文の仮決めを読める
        app.tabBars.buttons["任意判断"].tap()
        let decisionLog = app.staticTexts["epic/mvp の仮決め一覧"]
        XCTAssertTrue(decisionLog.waitForExistence(timeout: 5))
        decisionLog.tap()
        let decision = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "自動更新の間隔")).firstMatch
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["GitHub で開く"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "issue-detail-decision-log"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
