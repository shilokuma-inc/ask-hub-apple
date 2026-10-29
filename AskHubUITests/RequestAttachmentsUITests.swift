import XCTest

// 「新しい依頼」の添付欄（Discussion #669）。システムのファイルピッカーは別のプロセスなので操作せず、サンプルの添付を入れた状態から確かめる
extension AskHubUITests {
    @MainActor
    func testRequestAttachmentsListDeleteAndSend() throws {
        let app = XCUIApplication()
        // サンプルデータでは添付を上げたことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox", "-AskHubSampleAttachments"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        app.buttons["repository-picker"].tap()
        app.buttons["notti-ios"].tap()
        let summary = app.textFields["例: 通知の頻度を調整したい"]
        summary.tap()
        summary.typeText("通知の頻度を調整したい")
        app.buttons["keyboard-done"].tap()
        let body = app.textFields["やりたいこと・背景・決まっていることなど"]
        body.tap()
        body.typeText("朝だけにしたい")
        app.buttons["keyboard-done"].tap()

        // 添付欄は依頼文の下。名前・種類・大きさと、public の注意書きを出す（Form は画面の外の行を作らないので、出るまでスクロールする）
        let memo = app.staticTexts["memo.md"]
        for _ in 0..<4 where !memo.exists {
            app.swipeUp()
        }
        XCTAssertTrue(memo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["design.png"].exists)
        XCTAssertTrue(app.staticTexts["画像・117 KB"].exists)
        assertZipAndSVGRows(in: app)
        let notice = NSPredicate(format: "label CONTAINS %@", "public のリポジトリでは、添付したファイルは誰でも見られます")
        XCTAssertTrue(app.staticTexts.matching(notice).firstMatch.exists)
        let limits = NSPredicate(format: "label CONTAINS %@", "zip は 50.0 MB まで")
        XCTAssertTrue(app.staticTexts.matching(limits).firstMatch.exists)
        XCTAssertTrue(app.buttons["ファイルを添付"].exists)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "request-attachments-list"
        list.lifetime = .keepAlways
        add(list)

        // 削除のボタンで一覧から外す（macOS にはスワイプの削除が無いので、ボタンで消す）
        app.buttons["memo.md を削除"].tap()
        XCTAssertTrue(memo.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["design.png"].exists)

        let send = app.buttons["依頼を送る"]
        for _ in 0..<3 where !send.isHittable {
            app.swipeUp()
        }
        send.tap()

        // 送れたら添付の数を添えて出し、添付の一覧を空にする
        let sent = app.staticTexts["notti-ios に「通知の頻度を調整したい」を依頼しました（添付 3 件）"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["design.png"].exists)
        let done = XCTAttachment(screenshot: app.screenshot())
        done.name = "request-attachments-sent"
        done.lifetime = .keepAlways
        add(done)
    }

    /// サンプルの zip と SVG も、名前・種類・大きさを出す（Discussion #761）。画面の外なら出るまでスクロールする
    @MainActor
    func assertZipAndSVGRows(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let zip = app.staticTexts["assets.zip"]
        for _ in 0..<3 where !zip.exists {
            app.swipeUp()
        }
        XCTAssertTrue(zip.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.staticTexts["zip・3.0 MB"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["icon.svg"].exists, file: file, line: line)
    }
}
