import XCTest

// 「新しい依頼」の「リリース準備」（Discussion #605）。デモのサンプル（SampleRelease.swift）で、起動したことにした run は数秒で成功する
extension AskHubUITests {
    @MainActor
    func testReleaseRequestFillsDefaultVersionAndConfirms() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()
        openReleaseRequest(in: app)
        XCTAssertTrue(app.navigationBars["リリース準備"].waitForExistence(timeout: 5))

        // リポジトリを選ぶと、develop の MARKETING_VERSION（サンプルは 1.2.0）の次のマイナーが入る
        chooseReleaseRepository("ask-hub-apple", in: app)
        let version = app.textFields["release-version"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == %@", "1.3.0"), evaluatedWith: version)
        waitForExpectations(timeout: 5)
        // LabeledContent は名前と値をつないだ StaticText になる（LEARNINGS.md）
        XCTAssertTrue(app.staticTexts["ブランチ, release/1.3.0"].exists)

        // 送る前に確認ダイアログを出す
        let start = app.buttons["start-release"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        XCTAssertTrue(app.staticTexts["1.3.0 のリリース準備を始めますか？"].waitForExistence(timeout: 5))
        // ダイアログのボタンは元のボタンと同じ文言なので、identifier で分ける（LEARNINGS.md）
        let dialogStart = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "リリース準備を始める", "start-release")
        ).firstMatch
        XCTAssertTrue(dialogStart.waitForExistence(timeout: 5))
        dialogStart.tap()

        // 始めたバージョンが準備中のリリースになり、その進み具合がリポジトリの欄の下に入るので、run の欄は下にずれる
        XCTAssertTrue(app.staticTexts["準備中のリリース: release/1.3.0"].waitForExistence(timeout: 10))
        // 起動した run（run-name にバージョン）が出る
        XCTAssertTrue(scrollToReleaseText("run, リリース準備 1.3.0", in: app))
        for _ in 0..<3 where !start.exists {
            app.swipeUp()
        }
        XCTAssertFalse(start.isEnabled)
        let prepareStep = app.descendants(matching: .any)["release-step-prepare"]
        for _ in 0..<3 where !prepareStep.exists {
            app.swipeDown()
        }
        XCTAssertTrue(prepareStep.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["準備中のリリース: release/1.3.0"].exists)
    }

    /// 準備中のリリース（サンプルの notti-ios は release/2.1.0 に下書きがある）の進み具合から、最新情報の画面を開いて確定する
    @MainActor
    func testReleaseProgressOpensDraftAndConfirms() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()
        openReleaseRequest(in: app)
        chooseReleaseRepository("notti-ios", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["release-step-notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["下書きがあります。確かめて確定してください"].exists)
        // iOS の Form は画面の外の行を作らないので、下の行はスクロールしてから探す（LEARNINGS.md）
        let openNotes = app.buttons["open-release-notes"]
        for _ in 0..<3 where !openNotes.exists {
            app.swipeUp()
        }
        openNotes.tap()
        XCTAssertTrue(app.navigationBars["最新情報"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["状態, 下書き（未確定）"].waitForExistence(timeout: 5))
        let text = app.textViews["whats-new-ja"].exists ? app.textViews["whats-new-ja"] : app.textFields["whats-new-ja"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String)?.contains("曜日ごと") == true)

        let confirm = app.buttons["confirm-release-notes"]
        for _ in 0..<3 where !confirm.exists {
            app.swipeUp()
        }
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["2.1.0 の最新情報を確定しますか？"].waitForExistence(timeout: 5))
        let dialogConfirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "確定して反映", "confirm-release-notes")
        ).firstMatch
        XCTAssertTrue(dialogConfirm.waitForExistence(timeout: 5))
        dialogConfirm.tap()

        // 確定の run が終わったら（サンプルは数秒）、読み直すと確定済みになる
        let confirmed = app.staticTexts["状態, 確定済み"]
        let refresh = app.navigationBars["最新情報"].buttons["更新"]
        for _ in 0..<10 where !confirmed.exists {
            app.swipeDown()
            if refresh.isEnabled {
                refresh.tap()
            }
            _ = confirmed.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(confirmed.exists)
        XCTAssertTrue(app.staticTexts["確定の run, 成功"].exists)

        // 進み具合も確定済みになり、配信を待つ
        app.navigationBars["最新情報"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["確定しました"].waitForExistence(timeout: 5))
    }

    /// サンプルの準備中・配信待ち・完了のリリースの進み具合
    @MainActor
    func testReleaseDemoShowsEachState() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AskHubSampleInbox"]
        app.launch()
        openReleaseRequest(in: app)

        chooseReleaseRepository("claude-plugins", in: app)
        XCTAssertTrue(app.staticTexts["準備中のリリース: release/0.4.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["release ブランチの用意と App Store Connect のバージョンの作成を進めています"].waitForExistence(timeout: 5))

        chooseReleaseRepository("web-tools", in: app)
        XCTAssertTrue(app.staticTexts["準備中のリリース: release/1.5.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToReleaseText("審査への提出と配信を待っています。App Store Connect の状態はアプリでは見られません", in: app))

        chooseReleaseRepository("sandbox", in: app)
        XCTAssertTrue(app.staticTexts["準備中のリリース: release/0.9.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToReleaseText("リリース後作業が終わりました。更新するとタグを確かめます", in: app))
    }

    private func openReleaseRequest(in app: XCUIApplication) {
        app.tabBars.buttons["依頼"].tap()
        let picker = app.segmentedControls["request-kind-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["リリース準備"].tap()
    }

    /// リリースするリポジトリを選ぶ。リポジトリの欄が画面の外にあれば、上に戻してから開く
    private func chooseReleaseRepository(_ name: String, in app: XCUIApplication) {
        let repositoryPicker = app.buttons["release-repository-picker"]
        for _ in 0..<3 where !(repositoryPicker.exists && repositoryPicker.isHittable) {
            app.swipeDown()
        }
        XCTAssertTrue(repositoryPicker.waitForExistence(timeout: 5))
        repositoryPicker.tap()
        let repository = app.buttons[name]
        XCTAssertTrue(repository.waitForExistence(timeout: 5))
        repository.tap()
    }

    /// 進み具合の下のほうの段の説明を、スクロールして探す
    private func scrollToReleaseText(_ text: String, in app: XCUIApplication) -> Bool {
        let element = app.staticTexts[text]
        for _ in 0..<4 where !element.exists {
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 2)
    }
}
