import XCTest

// Siri・ショートカットからの依頼の使い方（Discussion #655 の Q1 の補足）。設定と「新しい依頼」から開ける
extension AskHubUITests {
    @MainActor
    func testOpenSiriShortcutsHelpFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        // 行はトークンの案内などの下にあり、Form は画面の外の行を作らないので、出るまでスクロールする
        let link = app.buttons["siri-help-link"]
        scrollUntilHittableInForm(link, in: app)
        link.tap()

        XCTAssertTrue(app.navigationBars["Siri とショートカット"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["「AskHubで依頼」"].exists)
    }

    @MainActor
    func testOpenSiriShortcutsHelpFromNewRequest() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        XCTAssertTrue(app.buttons["依頼を送る"].waitForExistence(timeout: 5))
        let link = app.buttons["siri-help-request-link"]
        scrollUntilHittableInForm(link, in: app)
        link.tap()

        XCTAssertTrue(app.navigationBars["Siri とショートカット"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["「AskHubに依頼を送る」"].exists)
    }

    /// Form の行が画面に出るまでスクロールする
    @MainActor
    private func scrollUntilHittableInForm(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return
            }
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) が画面に出ない", file: file, line: line)
    }
}
