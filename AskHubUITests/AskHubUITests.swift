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
        // 担当の印が無いリポジトリの開始待ちは「担当 PC なし」と出る
        XCTAssertTrue(app.staticTexts["担当 PC なし"].exists)
    }

    @MainActor
    func testSendIdeaRequest() throws {
        let app = XCUIApplication()
        // サンプルデータでは Issue を作ったことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        let send = app.buttons["依頼を送る"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)

        app.buttons["repository-picker"].tap()
        app.buttons["notti-ios"].tap()
        let summary = app.textFields["例: 通知の頻度を調整したい"]
        summary.tap()
        summary.typeText("通知の頻度を調整したい")
        let body = app.textFields["やりたいこと・背景・決まっていることなど"]
        body.tap()
        body.typeText("朝だけにしたい")
        send.tap()

        XCTAssertTrue(app.staticTexts["依頼を送りました"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAnswerQuestionFromDetail() throws {
        let app = XCUIApplication()
        // サンプルデータでは投稿しても GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        let row = app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // 投稿ボタンは画面の下にあるので、スクロールして表示する
        app.swipeUp()

        let post = app.buttons["回答を投稿"]
        XCTAssertTrue(post.waitForExistence(timeout: 5))
        XCTAssertFalse(post.isEnabled)
        app.buttons["1時間"].tap()
        XCTAssertTrue(post.isEnabled)
        post.tap()

        // 投稿すると一覧に戻る
        XCTAssertTrue(app.navigationBars["要回答"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStartLoopWhenAnsweringLastQuestionOfDiscussion() throws {
        let app = XCUIApplication()
        // サンプルデータでは投稿もループの開始も GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 1 つ目の質問に答える（まだ未回答の質問が残るので、ループは始められない）
        app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["この Discussion には、ほかに未回答の質問が 1 件あります"].waitForExistence(timeout: 5))
        app.buttons["1時間"].tap()
        app.buttons["回答を投稿"].tap()

        // 最後の質問では、投稿と一緒にループを始められる
        let lastQuestion = app.staticTexts["Q2. 通知の文言 通知に表示する文言の案があれば教えてください。"]
        XCTAssertTrue(lastQuestion.waitForExistence(timeout: 5))
        lastQuestion.tap()
        app.swipeUp()
        let toggle = app.switches["投稿したら、回答を確定してループを始める"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.tap()
        let note = app.textFields["回答"]
        note.tap()
        note.typeText("朝の通知だけにしたい")
        app.buttons["回答を投稿してループを始める"].tap()

        // 確かめてから始める
        let confirm = app.buttons["投稿してループを始める"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["要回答"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMergeEpicAfterConfirmation() throws {
        let app = XCUIApplication()
        // サンプルデータではマージしたことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["マージ待ち"].tap()
        let row = app.staticTexts["【FEAT】epic/mvp を develop に取り込む"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        app.swipeUp()
        let merge = app.buttons["develop にマージ"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertTrue(merge.isEnabled)
        merge.tap()

        // 確かめてからマージする
        let confirm = app.buttons["develop にマージする"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["マージ待ち"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["【FEAT】epic/mvp を develop に取り込む"].exists)
    }
}
