//
//  AskHubUITests.swift
//  AskHubUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import XCTest

final class AskHubUITests: XCTestCase {
    override func setUpWithError() throws {
        // UI テストでは失敗した時点で即座に止める
        continueAfterFailure = false
    }

    @MainActor
    func testInboxShowsBothTabs() throws {
        let app = XCUIApplication()
        // GitHub に接続せず、アプリに組み込んだサンプルデータを表示する
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        XCTAssertTrue(app.staticTexts["通知の頻度を調整したい"].firstMatch.waitForExistence(timeout: 5))

        app.tabBars.buttons["急がない"].tap()
        XCTAssertTrue(app.staticTexts["【CHORE】epic/mvp の仮決め一覧"].waitForExistence(timeout: 5))
    }
}
