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

// 実機確認の「問題あり」（Issue #483）
extension AskHubUITests {
    @MainActor
    func testReportVerificationProblem() throws {
        let app = XCUIApplication()
        // サンプルデータでは依頼とコメントを作ったことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["実機確認"].tap()
        let row = app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // 「問題あり」は本文と「確認済みとして閉じる」の下にある（Form は画面の外の行を作らないので、出るまでスクロールする）
        XCTAssertTrue(app.staticTexts["確認手順"].waitForExistence(timeout: 5))
        let field = app.textFields["何をしたら・どうなったか"]
        for _ in 0..<4 where !field.exists {
            app.swipeUp()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // 問題の内容が空なら送れない
        let send = app.buttons["問題ありとして再修正を依頼する"]
        XCTAssertFalse(send.isEnabled)
        field.tap()
        field.typeText("保存した PAT が再起動後に消える")
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(send.isEnabled)
        send.tap()

        // 送る内容を見せて確かめてから、依頼とコメントを送る
        let confirm = app.buttons["依頼する"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let title = NSPredicate(format: "label CONTAINS %@", "【依頼】実機確認の問題: PAT の Keychain への保存")
        XCTAssertTrue(app.staticTexts.matching(title).firstMatch.exists)
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "verify-problem-confirmation"
        confirmation.lifetime = .keepAlways
        add(confirmation)
        confirm.tap()

        XCTAssertTrue(app.staticTexts["再修正の依頼 #41 を作り、この Issue にコメントしました"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["依頼を GitHub で開く"].exists)
        let sent = XCTAttachment(screenshot: app.screenshot())
        sent.name = "verify-problem-sent"
        sent.lifetime = .keepAlways
        add(sent)

        // 実機確認 Issue は閉じない（一覧に戻っても残る）
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["実機確認"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PAT の Keychain への保存と macOS の設定画面の見た目"].exists)
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

// 任意判断の詳細画面の、指示とループの返信の履歴（Discussion #349）
extension AskHubUITests {
    @MainActor
    func testDecisionLogShowsInstructionHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["任意判断"].tap()
        let decisionLog = app.staticTexts["epic/mvp の仮決め一覧"]
        XCTAssertTrue(decisionLog.waitForExistence(timeout: 5))
        decisionLog.tap()

        // 履歴は本文の下にある（Form は画面の外の行を作らないので、出るまでスクロールする）
        let unprocessed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "未処理の指示が 1 件あります")).firstMatch
        for _ in 0..<12 where !unprocessed.exists {
            app.swipeUp()
        }
        XCTAssertTrue(unprocessed.waitForExistence(timeout: 5))
        let untrusted = app.staticTexts["信用外（指示として扱わない）"]
        for _ in 0..<3 where !untrusted.exists {
            app.swipeUp()
        }
        XCTAssertTrue(untrusted.exists)
        XCTAssertTrue(app.staticTexts["指示・処理済み"].exists || app.staticTexts["ループの返信"].exists)
        // ループの返信の目印は本文に出さない
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "ask-hub:decision-reply")).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "decision-history"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
