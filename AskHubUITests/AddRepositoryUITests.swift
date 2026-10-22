import XCTest

// 依頼タブの「担当に入れる」（Discussion #722）
extension AskHubUITests {
    @MainActor
    func testSendAddRepositoryRequest() throws {
        let app = XCUIApplication()
        // サンプルデータでは ask-hub-apple に担当 PC がいて、notti-ios にはいない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        let kind = app.segmentedControls["request-kind-picker"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        let addRepository = kind.buttons["担当に入れる"]
        addRepository.tap()
        XCTAssertTrue(addRepository.isSelected)
        XCTAssertTrue(app.navigationBars["担当に入れる"].waitForExistence(timeout: 5))

        // 入れる先の PC は、担当 PC のいるリポジトリの先頭が選ばれている
        let hubPicker = app.buttons["add-hub-picker"]
        XCTAssertTrue(hubPicker.waitForExistence(timeout: 5))
        let send = app.buttons["担当に入れる依頼を送る"]
        XCTAssertFalse(send.isEnabled)

        // 担当 PC のいるリポジトリを選ぶと、断られる旨を出す（送信は止めない）
        let repositoryPicker = app.buttons["add-repository-picker"]
        repositoryPicker.tap()
        let assigned = app.buttons["beat-tap-ios"]
        XCTAssertTrue(assigned.waitForExistence(timeout: 5))
        assigned.tap()
        let warning = app.staticTexts["add-repository-assigned-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)

        // 担当 PC のいないリポジトリを選ぶと警告が消え、送ると送った依頼に出て選択が空に戻る
        repositoryPicker.tap()
        let unassigned = app.buttons["notti-ios"]
        XCTAssertTrue(unassigned.waitForExistence(timeout: 5))
        unassigned.tap()
        XCTAssertFalse(warning.waitForExistence(timeout: 2))
        scrollToHittable(send, in: app)
        send.tap()
        XCTAssertTrue(app.staticTexts["notti-ios を担当に入れる依頼をしました"].waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
    }
}
