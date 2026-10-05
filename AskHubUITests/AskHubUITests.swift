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
        // HTML タグと Markdown が混ざった質問のサンプルも一覧に出る
        XCTAssertTrue(app.staticTexts["HTMLタグの有効化"].firstMatch.exists)

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
    func testDismissKeyboardInNewRequest() throws {
        let app = XCUIApplication()
        // サンプルデータでは Issue を作ったことにして GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["依頼"].tap()
        app.buttons["repository-picker"].tap()
        app.buttons["notti-ios"].tap()
        let summary = app.textFields["例: 通知の頻度を調整したい"]
        summary.tap()
        summary.typeText("通知の頻度を調整したい")

        // 依頼文の Return は改行のままで、キーボードは閉じない
        let body = app.textFields["やりたいこと・背景・決まっていることなど"]
        body.tap()
        body.typeText("朝だけにしたい\n夜は止めたい")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // 入力すると placeholder では引けなくなるので、入力した値で探す
        let multiline = NSPredicate(format: "value CONTAINS %@", "朝だけにしたい\n夜は止めたい")
        XCTAssertTrue(app.textFields.matching(multiline).firstMatch.exists)

        // キーボード上の「完了」で閉じると、下の「依頼を送る」が押せる
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let send = app.buttons["依頼を送る"]
        XCTAssertTrue(send.isHittable)
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
        // 投稿される 1 行目を、投稿の前に確かめられる
        XCTAssertTrue(app.staticTexts["選択肢を選んでください"].exists)
        app.buttons["1時間"].tap()
        XCTAssertTrue(post.isEnabled)
        XCTAssertTrue(app.staticTexts["回答: 1時間"].exists)
        post.tap()

        // 投稿すると一覧に戻る
        XCTAssertTrue(app.navigationBars["要回答"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testQuestionDetailRendersHTMLAsBlocks() throws {
        let app = XCUIApplication()
        // HTML タグと Markdown が混ざった質問のサンプル（#163）を開く
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        let row = app.staticTexts["HTMLタグの有効化"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // <h3> と ### の見出し、<li> と - の箇条書きが、タグや記号の無い文字として出る
        XCTAssertTrue(app.staticTexts["Q1. 解釈するタグの範囲"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["よく使うタグ: 見出し・太字・箇条書き・コード・リンク"].exists)
        XCTAssertTrue(app.staticTexts["補足（Markdown）"].exists)
        XCTAssertTrue(app.staticTexts["見出しは ### Q1. の書き方も混ざる"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<h3>Q1.")).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "question-detail-html"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    func testMergeDetailRendersHTMLAsBlocks() throws {
        let app = XCUIApplication()
        // HTML タグと Markdown が混ざった PR 本文のサンプル（#163）を開く
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        app.tabBars.buttons["マージ待ち"].tap()
        let row = app.staticTexts["【FEAT】epic/html-rendering を develop に取り込む"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // <h3> と ### の見出し、<li> と - の箇条書きが、タグや記号の無い文字として出る
        let heading = app.staticTexts["回答待ちの PR"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["返答のない仮決め（既定値のまま確定）"].exists)
        XCTAssertTrue(app.staticTexts["実機確認 Issue"].exists)
        // 「状態」の「コンフリクト: なし」と区別するため、「まとめ」の見出しより下から始まる「なし」を箇条書きの項目とみなす
        // （見出しの accessibility frame はブロック全体に広がるので、上端どうしで比べる）
        let items = app.staticTexts.matching(NSPredicate(format: "label == %@", "なし")).allElementsBoundByIndex
        XCTAssertTrue(items.contains { $0.frame.minY > heading.frame.minY })
        XCTAssertTrue(app.staticTexts["#161 の 6 件。エンティティのデコード範囲と <br> の変換を含む。詳細は #161"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "<h3>")).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "merge-detail-html"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
