import XCTest

// 「新しい依頼」の「リリース準備」（Discussion #605）。リリースの各状態のサンプルと確定までの UI テストはタスク 15 で足す
extension AskHubUITests {
    @MainActor
    func testReleaseRequestFillsDefaultVersionAndConfirms() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        let picker = app.segmentedControls["request-kind-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["リリース準備"].tap()
        XCTAssertTrue(app.navigationBars["リリース準備"].waitForExistence(timeout: 5))

        // リポジトリを選ぶと、develop の MARKETING_VERSION（サンプルは 1.2.0）の次のマイナーが入る
        let repositoryPicker = app.buttons["release-repository-picker"]
        XCTAssertTrue(repositoryPicker.waitForExistence(timeout: 5))
        repositoryPicker.tap()
        let repository = app.buttons["ask-hub-apple"]
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.tap()
        let version = app.textFields["release-version"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "1.3.0"), evaluatedWith: version)
        waitForExpectations(timeout: 5)
        // LabeledContent は名前と値をつないだ StaticText になる（LEARNINGS.md）
        XCTAssertTrue(app.staticTexts["ブランチ, release/1.3.0"].exists)

        // 送る前に確認ダイアログを出す
        let start = app.buttons["start-release"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.staticTexts["1.3.0 のリリース準備を始めますか？"].waitForExistence(timeout: 5))
    }
}
