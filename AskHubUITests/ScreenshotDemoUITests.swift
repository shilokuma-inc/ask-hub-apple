import XCTest

// App Store のスクリーンショットの撮影モード（Discussion #605 の Q3）
extension AskHubUITests {
    /// 撮影モードでは、サンプルデータで指定の画面を開き、デモモードの帯を出さない
    @MainActor
    func testScreenshotDemoOpensSceneWithoutDemoBanner() throws {
        let app = XCUIApplication()
        // -AskHubDemoMode YES は UserDefaults のデモモードがオンの状態を、書き換えずに再現する（引数のドメインは保存されない）。
        // オンでも撮影モードでは帯を出さないことを確かめる
        app.launchArguments += ["-screenshot-demo", "-screenshot-scene", "status", "-AskHubDemoMode", "YES"]
        app.launch()

        // 撮る画面のタブ（ステータス）で開き、サンプルデータが出る
        XCTAssertTrue(app.staticTexts["上限で待機中"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["ステータス"].isSelected)
        XCTAssertFalse(app.staticTexts["デモモード（サンプルデータ）"].exists)
    }
}
