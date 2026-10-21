import XCTest

// 「新しいアプリ」のプラットフォーム → テンプレートの選択（Discussion #705）
extension AskHubUITests {
    @MainActor
    func testSwitchPlatformInNewApp() throws {
        let app = XCUIApplication()
        // サンプルデータの Organization は shilokuma-inc と shilokuma-vision
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        let kind = app.segmentedControls["request-kind-picker"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        kind.buttons["新しいアプリ"].tap()

        let platform = app.segmentedControls["platform-picker"]
        XCTAssertTrue(platform.waitForExistence(timeout: 5))
        let iOS = platform.buttons["iOS"]
        let visionOS = platform.buttons["visionOS"]
        let templates = app.segmentedControls["template-picker"]
        let organization = app.buttons["organization-picker"]
        let name = app.textFields["repository-name"]

        // 既定は iOS で、iOS のテンプレート・一覧の先頭の Organization・iOS のリポジトリ名の例
        XCTAssertTrue(iOS.isSelected)
        XCTAssertEqual(templates.buttons.count, 2)
        XCTAssertTrue(templates.buttons["通常"].isSelected)
        XCTAssertTrue(templates.buttons["クイズ"].exists)
        XCTAssertTrue(organization.waitForExistence(timeout: 5))
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-inc"))
        XCTAssertEqual(name.placeholderValue, "例: my-app-ios")

        // visionOS にすると、visionOS のテンプレートだけになり、Organization が shilokuma-vision に切り替わる
        templates.buttons["クイズ"].tap()
        visionOS.tap()
        XCTAssertTrue(visionOS.isSelected)
        XCTAssertEqual(templates.buttons.count, 1)
        XCTAssertTrue(templates.buttons["通常"].isSelected)
        XCTAssertFalse(templates.buttons["クイズ"].exists)
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-vision"))
        XCTAssertEqual(name.placeholderValue, "例: my-app-visionos")

        // 切り替えた後も Organization は選び直せる
        organization.tap()
        let inc = app.buttons["shilokuma-inc"]
        XCTAssertTrue(inc.waitForExistence(timeout: 5))
        inc.tap()
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-inc"))
        XCTAssertTrue(visionOS.isSelected)

        // iOS に戻すと、iOS の先頭のテンプレートと一覧の先頭の Organization に戻る。もう一度 visionOS にすると shilokuma-vision に戻る
        iOS.tap()
        XCTAssertTrue(iOS.isSelected)
        XCTAssertEqual(templates.buttons.count, 2)
        XCTAssertTrue(templates.buttons["通常"].isSelected)
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-inc"))
        XCTAssertEqual(name.placeholderValue, "例: my-app-ios")
        visionOS.tap()
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-vision"))
        iOS.tap()
        XCTAssertTrue(organizationLabel(of: organization).contains("shilokuma-inc"))
    }

    /// メニューの Picker の、見出しと選んでいる値をつないだ文字列（値が label と value のどちらに入るかは OS で変わりうる）
    @MainActor
    private func organizationLabel(of picker: XCUIElement) -> String {
        "\(picker.label) \(picker.value as? String ?? "")"
    }
}
