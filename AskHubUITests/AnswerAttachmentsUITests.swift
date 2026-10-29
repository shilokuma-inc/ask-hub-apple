import XCTest

// 質問への回答の添付（Discussion #669 のタスク 7）。システムのファイルピッカーは操作せず、サンプルの添付を入れた状態から確かめる
extension AskHubUITests {
    @MainActor
    func testAnswerWithAttachments() throws {
        let app = XCUIApplication()
        // サンプルデータでは添付を上げたことにして、回答も GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox", "-AskHubSampleAttachments"]
        app.launch()

        let row = app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["1時間"].tap()

        // 添付欄は補足の下。名前・種類・大きさと、public の注意書きを出す
        let memo = app.staticTexts["memo.md"]
        for _ in 0..<4 where !memo.exists {
            app.swipeUp()
        }
        XCTAssertTrue(memo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["design.png"].exists)
        assertZipAndSVGRows(in: app)
        let notice = NSPredicate(format: "label CONTAINS %@", "public のリポジトリでは、添付したファイルは誰でも見られます")
        // zip と SVG の行で注意書きが画面の下に押し出されるので、出るまでスクロールする
        scrollToHittable(app.staticTexts.matching(notice).firstMatch, in: app)
        XCTAssertTrue(app.staticTexts.matching(notice).firstMatch.exists)
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "answer-attachments-list"
        list.lifetime = .keepAlways
        add(list)

        scrollToHittable(app.buttons["memo.md を削除"], in: app)
        app.buttons["memo.md を削除"].tap()
        XCTAssertTrue(memo.waitForNonExistence(timeout: 5))

        // 1 行目の「回答: 」は今までどおり出る
        let post = app.buttons["回答を投稿"]
        for _ in 0..<3 where !post.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["回答: 1時間"].exists)
        post.tap()

        // 投稿すると一覧に戻る
        XCTAssertTrue(app.navigationBars["要対応"].waitForExistence(timeout: 5))
    }
}
