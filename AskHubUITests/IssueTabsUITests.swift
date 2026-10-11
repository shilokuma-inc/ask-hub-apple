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
        // 仮決め一覧はオーケストレーターが閉じるので、アプリからは閉じさせない
        XCTAssertFalse(app.buttons["確認済みとして閉じる"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "issue-detail-decision-log"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testCloseVerificationIssueAfterConfirmation() throws {
        let app = XCUIApplication()
        // サンプルデータでは閉じたことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["実機確認"].tap()
        let row = app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // ボタンは本文の下にある（Form は画面の外の行を作らないので、出るまでスクロールする）
        let close = app.buttons["確認済みとして閉じる"]
        XCTAssertTrue(app.staticTexts["確認手順"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !close.exists {
            app.swipeUp()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        // 確かめてから閉じる。閉じたら一覧に戻り、その行が消える
        let confirm = app.buttons["閉じる"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "issue-detail-close-confirmation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["実機確認"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["通知の許可ダイアログと届いた通知の表示"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"].exists)
    }
}

// 任意判断の詳細画面での承認・指示（Discussion #349）
extension AskHubUITests {
    @MainActor
    func testApproveAndInstructDecisionItems() throws {
        let app = XCUIApplication()
        // サンプルデータでは承認・投稿したことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["任意判断"].tap()
        let decisionLog = app.staticTexts["epic/mvp の仮決め一覧"]
        XCTAssertTrue(decisionLog.waitForExistence(timeout: 5))
        decisionLog.tap()

        // 確認済みの項目は承認済み・変更済みとして出す
        XCTAssertTrue(app.staticTexts["承認済み"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["変更済み: 別案 1（52pt）"].exists)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "decision-items"
        overview.lifetime = .keepAlways
        add(overview)

        // 別案を選ぶと、送るコメントを見せて確かめる
        let changeInterval = app.buttons["別案 2: 15 分"]
        for _ in 0..<3 where !changeInterval.exists {
            app.swipeUp()
        }
        XCTAssertTrue(changeInterval.waitForExistence(timeout: 5))
        changeInterval.tap()
        let confirmInstruction = app.buttons["投稿する"]
        XCTAssertTrue(confirmInstruction.waitForExistence(timeout: 5))
        let instructionDialog = XCTAttachment(screenshot: app.screenshot())
        instructionDialog.name = "decision-instruction-confirmation"
        instructionDialog.lifetime = .keepAlways
        add(instructionDialog)
        confirmInstruction.tap()
        XCTAssertTrue(app.staticTexts["指示を送りました。ループが次の周回で読みます"].waitForExistence(timeout: 5))
        let instructed = XCTAttachment(screenshot: app.screenshot())
        instructed.name = "decision-instructed"
        instructed.lifetime = .keepAlways
        add(instructed)

        // 採用のまま承認する。確かめてから本文のチェックを付け、承認済みとして出し直す
        let approve = app.buttons["採用のまま（承認）"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        let confirmApproval = app.buttons["承認する"]
        XCTAssertTrue(confirmApproval.waitForExistence(timeout: 5))
        let approvalDialog = XCTAttachment(screenshot: app.screenshot())
        approvalDialog.name = "decision-approve-confirmation"
        approvalDialog.lifetime = .keepAlways
        add(approvalDialog)
        confirmApproval.tap()
        XCTAssertTrue(app.staticTexts["承認しました"].waitForExistence(timeout: 5))
        XCTAssertFalse(changeInterval.exists, "承認した項目には別案のボタンを出さない")
        let approved = XCTAttachment(screenshot: app.screenshot())
        approved.name = "decision-approved"
        approved.lifetime = .keepAlways
        add(approved)
    }
}
