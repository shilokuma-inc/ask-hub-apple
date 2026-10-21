import XCTest

// 質問の詳細画面からの回答と、最後の質問でのループの開始
extension AskHubUITests {
    @MainActor
    func testAnswerQuestionFromDetail() throws {
        let app = XCUIApplication()
        // サンプルデータでは投稿しても GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        let row = app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // 投稿ボタンは画面の下（添付欄の下）にあるので、スクロールして表示する
        let post = app.buttons["回答を投稿"]
        scrollToHittable(post, in: app)
        XCTAssertFalse(post.isEnabled)
        // 投稿される 1 行目を、投稿の前に確かめられる
        scrollToHittable(app.staticTexts["選択肢を選んでください"], in: app)
        // 選択肢は画面の上にある。いちばん上まで戻し、スクロールが止まってから選ぶ（動いている間のタップは選択にならない）
        for _ in 0..<4 {
            app.swipeDown()
        }
        let option = app.buttons["1時間"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.isHittable)
        option.tap()
        scrollToHittable(post, in: app)
        // スクロールの後は画面の更新を待ってから確かめる
        XCTAssertTrue(post.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertTrue(app.staticTexts["回答: 1時間"].waitForExistence(timeout: 5))
        post.tap()

        // 投稿すると一覧に戻る
        XCTAssertTrue(app.navigationBars["要対応"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDismissKeyboardInQuestionDetail() throws {
        let app = XCUIApplication()
        // サンプルデータでは投稿しても GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        let row = app.staticTexts["Q2. 通知の文言 通知に表示する文言の案があれば教えてください。"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // 回答の欄と投稿ボタンは画面の下にあるので、スクロールして表示する
        app.swipeUp()

        // 回答の Return は改行のままで、キーボードは閉じない
        let note = app.textFields["回答"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("朝の通知だけにしたい\n夜は送らない")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let multiline = NSPredicate(format: "value CONTAINS %@", "朝の通知だけにしたい\n夜は送らない")
        XCTAssertTrue(app.textFields.matching(multiline).firstMatch.exists)

        // キーボード上の「完了」で閉じると、下の「回答を投稿」が押せる
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let post = app.buttons["回答を投稿"]
        XCTAssertTrue(post.isHittable)
        post.tap()

        // 投稿すると一覧に戻る
        XCTAssertTrue(app.navigationBars["要対応"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStartLoopWhenAnsweringLastQuestionOfDiscussion() throws {
        let app = XCUIApplication()
        // サンプルデータでは投稿もループの開始も GitHub には送らない
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 1 つ目の質問に答える（まだ未回答の質問が残るので、ループは始められない）
        app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"].tap()
        let option = app.buttons["1時間"]
        scrollToHittable(option, in: app)
        option.tap()
        let remaining = app.staticTexts["この Discussion には、ほかに未回答の質問が 1 件あります"]
        scrollToHittable(remaining, in: app)
        let post = app.buttons["回答を投稿"]
        scrollToHittable(post, in: app)
        post.tap()

        // 最後の質問では、投稿と一緒にループを始められる。「投稿したらループを始める」は既定でオン（Issue #98）
        let lastQuestion = app.staticTexts["Q2. 通知の文言 通知に表示する文言の案があれば教えてください。"]
        XCTAssertTrue(lastQuestion.waitForExistence(timeout: 5))
        lastQuestion.tap()
        let note = app.textFields["回答"]
        scrollToHittable(note, in: app)
        note.tap()
        note.typeText("朝の通知だけにしたい")
        app.buttons["keyboard-done"].tap()
        let toggle = app.switches["投稿したら、回答を確定してループを始める"]
        scrollToHittable(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        let postAndStart = app.buttons["回答を投稿してループを始める"]
        scrollToHittable(postAndStart, in: app)
        postAndStart.tap()

        // 確かめてから始める
        let confirm = app.buttons["投稿してループを始める"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["要対応"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testStartLoopDefaultFollowsSettings() throws {
        let app = XCUIApplication()
        // サンプルデータの起動引数では、設定画面の既定値（オン）から始まる
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()

        // 設定画面のスイッチは初期値オン。オフにする（Discussion #244 の Q1）
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        // スイッチはトークンの案内などの下にあり、Form は画面の外の行を作らないので、設定画面が開いてから出るまでスクロールする
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5))
        let preference = app.switches["投稿したらループを始める"]
        scrollToHittable(preference, in: app)
        XCTAssertEqual(preference.value as? String, "1")
        preference.switches.firstMatch.tap()
        XCTAssertEqual(preference.value as? String, "0")
        app.buttons["完了"].tap()

        // 1 つ目の質問に答えて、最後の質問を開く
        let firstQuestion = app.staticTexts["Q1. レート制限の単位 送信の上限をどの単位で数えますか？"]
        XCTAssertTrue(firstQuestion.waitForExistence(timeout: 5))
        firstQuestion.tap()
        let option = app.buttons["1時間"]
        scrollToHittable(option, in: app)
        option.tap()
        let post = app.buttons["回答を投稿"]
        scrollToHittable(post, in: app)
        post.tap()
        let lastQuestion = app.staticTexts["Q2. 通知の文言 通知に表示する文言の案があれば教えてください。"]
        XCTAssertTrue(lastQuestion.waitForExistence(timeout: 5))
        lastQuestion.tap()

        // 回答画面のトグルは設定の値（オフ）から始まり、投稿ボタンもループを始めない文言になる
        let toggle = app.switches["投稿したら、回答を確定してループを始める"]
        scrollToHittable(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.buttons["回答を投稿"].exists)
    }
}
