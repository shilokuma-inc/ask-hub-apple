//
//  AskHubUITestsLaunchTests.swift
//  AskHubUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import XCTest

final class AskHubUITestsLaunchTests: XCTestCase {
    /// 構成（縦横・ライトダーク）ごとには流さない。構成ごとに流すと XCTest が端末の向きを変え、CI の Simulator では
    /// 向きの変更の確認を待ちきれずに落ちる・横向きのまま残って後のテストが要素を見つけられないことがあった。起動のスクショは今の向きで 1 枚撮る
    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // 起動直後のスクリーンショットをテスト結果に添付する
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
