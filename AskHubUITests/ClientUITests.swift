import XCTest

/// 新しい画面の主な流れ（デモのデータで動かす。GitHub にもトークンにも依存しない）
final class ClientUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // 横向きのまま残った Simulator なら、縦向きに戻す。縦向きなら向きを変えない
        // （CI の Simulator では、向きの変更の確認を待ちきれずに落ちることがある。#1006）
        #if os(iOS)
        MainActor.assumeIsolated {
            if XCUIDevice.shared.orientation.isLandscape {
                XCUIDevice.shared.orientation = .portrait
            }
        }
        #endif
    }

    /// 一覧を下へ送りながら、要素が出るまで探す（一覧の行は画面に入るまで作られない）
    @MainActor
    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 4) -> Bool {
        for _ in 0..<maxSwipes where !element.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        return element.waitForExistence(timeout: 3)
    }

    /// デモの場面で起動する。機械の反応は既定ではすぐ起こす。スマホを持つ手は既定で右手
    @MainActor
    private func launch(_ arguments: [String], reactionDelay: Int = 0, hand: String = "right") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoReactionDelay", "\(reactionDelay)", "-swipeHand", hand] + arguments
        app.launch()
        return app
    }

    /// あなたの番に、進行を止めているものとまとめて判断する入口が出る
    @MainActor
    func testInboxShowsBlockingItems() {
        let app = launch(["-demoScenario", "standard"])
        XCTAssertTrue(app.staticTexts["進行が止まっています · 6"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["まとめて判断する"].exists)
        // 出番があるときは、空の画面の「新しい依頼を出す」を出さない
        XCTAssertFalse(app.buttons["新しい依頼を出す"].exists)
        // 「時間のあるときに」は下にあるので、一覧を送ってから確かめる（家事シェアの準備の 2 件を含む）
        XCTAssertTrue(scrollUntilExists(app.staticTexts["時間のあるときに · 7"], in: app))
    }

    /// 読めなかったときは、出番が無いときの空の画面を出さない
    @MainActor
    func testFailureIsNotShownAsEmpty() {
        let app = launch(["-demoScenario", "failing"])
        XCTAssertTrue(app.staticTexts["読み込めませんでした"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["いまは任せて大丈夫です"].exists)
        XCTAssertTrue(app.buttons["もう一度読む"].exists)
        XCTAssertFalse(app.buttons["新しい依頼を出す"].exists)
    }

    /// 人の出番が無いときは、機械が何件を進めているかを出す
    @MainActor
    func testQuietScenarioShowsEmptyState() {
        let app = launch(["-demoScenario", "quiet"])
        XCTAssertTrue(app.staticTexts["いまは任せて大丈夫です"].waitForExistence(timeout: 10))
    }

    /// 人の出番が無いときの画面から、ツールバーと同じ新しい依頼のシートを開ける
    @MainActor
    func testEmptyInboxOpensNewRequest() {
        let app = launch(["-demoScenario", "quiet"])
        let button = app.buttons["新しい依頼を出す"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        // メニューの選択は、名前に今の値が続いたボタンになる（例「アプリ, 選んでください」）
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "アプリ")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["キャンセル"].firstMatch.exists)
    }

    /// 設定でデモの場面を変えると、その場面のデータを読み込み直す（作り直した store を読み込まないまま残さない）。
    /// 起動引数の `-demoScenario` は設定より優先されるので付けず、見るデータだけをデモにする。最後に標準の場面に戻す
    @MainActor
    func testChangingScenarioReloadsData() {
        let app = launch(["-dataSource", "demo"])
        chooseScenario("人の出番が無い", in: app)
        XCTAssertTrue(app.staticTexts["いまは任せて大丈夫です"].waitForExistence(timeout: 10))
        chooseScenario("ひととおり（標準）", in: app)
        XCTAssertTrue(app.staticTexts["まとめて判断する"].waitForExistence(timeout: 10))
    }

    /// 状態リポジトリを見るときにトークンが無ければ、GitHub には送らずに、設定で入れるよう出す
    @MainActor
    func testStateRepositoryWithoutTokenAsksForToken() {
        let app = launch(["-dataSource", "stateRepository"])
        XCTAssertTrue(app.staticTexts["読み込めませんでした"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["GitHub のトークンがありません。設定で入れてください"].exists)
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["GitHub のトークン"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["トークン"].exists)
        // 鍵の節は設定の下のほうにあるので、シートを送りながら探す（後ろの一覧ではなく、前に出ているシートを送る）
        let key = app.staticTexts["この端末の鍵"]
        for _ in 0..<4 where !key.exists {
            app.swipeUp()
        }
        XCTAssertTrue(key.exists)
    }

    private func chooseScenario(_ label: String, in app: XCUIApplication) {
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        // メニューの選択は、名前に今の値が続いたボタンになる（例「デモの場面, ひととおり（標準）」）
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "デモの場面")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        picker.tap()
        app.buttons[label].firstMatch.tap()
        app.buttons["閉じる"].firstMatch.tap()
    }

    /// カードを右上へスワイプすると推奨で答え、猶予の間は取り消せる
    @MainActor
    func testSwipeAnswersAndCanUndo() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.staticTexts["書き出したファイルの置き場所"].exists)

        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 240, dy: -240)))

        let undo = app.buttons["取り消す"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["習慣ログ · 質問 Q2 / 4: ファイル App に保存"].exists)
        undo.tap()
        XCTAssertTrue(card.staticTexts["書き出したファイルの置き場所"].waitForExistence(timeout: 5))
    }

    /// まとめて判断するでは、前のカードを飛ばすと後ろのカードが前に出て、続けて答えられる
    @MainActor
    func testSwipeThroughDeck() {
        // 答えに反応して新しいカード（ロックが外れた質問）が割り込まないよう、機械の反応を遅くする
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:all"], reactionDelay: 600)
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let titles = ["まとめを届ける曜日と時刻", "書き出したファイルの置き場所", "ファイル名の決まり"]
        // ↗（推奨）と ↙ に続けて飛ばす
        let moves = [CGVector(dx: 240, dy: -240), CGVector(dx: -240, dy: 240)]
        for (index, move) in moves.enumerated() {
            XCTAssertTrue(card.staticTexts[titles[index]].waitForExistence(timeout: 5))
            let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(move))
        }
        XCTAssertTrue(card.staticTexts[titles[2]].waitForExistence(timeout: 5))
    }

    /// 選択肢を押しても答えられる（スワイプの代わり）
    @MainActor
    func testTapChoiceAnswers() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.buttons["共有シートだけ（左下へスワイプ）"].tap()
        XCTAssertTrue(app.staticTexts["習慣ログ · 質問 Q2 / 4: 共有シートだけ"].waitForExistence(timeout: 5))
    }

    /// 自由回答の選択肢（直してほしい）は、推奨の対角に置き、「自由回答」の札を付ける。左手では鏡写しになる
    @MainActor
    func testFreeTextChoiceSitsOppositeRecommended() {
        for (hand, recommended, freeText) in [("right", "右上", "左下"), ("left", "左上", "右下")] {
            let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:decisions:tsundoku-search"], hand: hand)
            let card = app.otherElements["deckCard.top"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(card.buttons["OK（推奨・\(recommended)へスワイプ）"].exists, hand)
            XCTAssertTrue(card.buttons["直してほしい（自由回答・\(freeText)へスワイプ）"].exists, hand)
            app.terminate()
        }
    }

    /// 自由回答（問題あり）の方向にスワイプすると、カードは飛ばずにその方向で止まり、文を書くシートが出る。
    /// シートの上には何について書いているか（札の題）を出し、iOS では入力欄を押すまでキーボードを出さない。
    /// 送らずに閉じると元の位置に戻り、書いて送るとカードが飛んで次のカードが出る
    @MainActor
    func testFreeAnswerSwipeHoldsCardUntilSent() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:verifications:habit-review"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let title = card.staticTexts["振り返りの画面を日曜の夜に開ける"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let resting = settledFrame(of: title)
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 120))
        let toFreeAnswer = CGVector(dx: -240, dy: 240)

        start.press(forDuration: 0.05, thenDragTo: start.withOffset(toFreeAnswer))
        let cancel = app.buttons["キャンセル"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        // 飛ばずに、左下へ決まる距離だけ動いた所に残る
        XCTAssertTrue(waitUntil { isHeldDownLeft(title, from: resting) }, "\(title.frame) / \(resting)")

        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil { isResting(title, at: resting) }, "\(title.frame) / \(resting)")

        start.press(forDuration: 0.05, thenDragTo: start.withOffset(toFreeAnswer))
        let send = app.buttons["送る"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let subject = app.descendants(matching: .any)["textRequest.subject"]
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        XCTAssertTrue(subject.label.contains("振り返りの画面を日曜の夜に開ける"), subject.label)
        let field = app.descendants(matching: .any)["textRequest.field"].firstMatch
        #if os(iOS)
        // 開いてすぐはキーボードを出さず、止めたカードを見せる。入力欄を押すと出る
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(keyboard.waitForExistence(timeout: 1.5))
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        #else
        field.tap()
        #endif
        app.typeText("crash")
        send.tap()
        XCTAssertTrue(app.buttons["取り消す"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["習慣ログ · 実機で確かめる · TestFlight 1.4.0 (52): 問題あり"].exists)
        XCTAssertTrue(card.staticTexts["グラフの色がダークモードでも読める"].waitForExistence(timeout: 5))
    }

    /// 数字キーや選択肢を押して自由回答を選んでも、カードを飛ばさずにその方向で止めてシートを出す。
    /// シートを下へ払って閉じても（キャンセルを押さなくても）元の位置に戻る
    @MainActor
    func testKeyAndTapFreeAnswerHoldCard() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:verifications:habit-review"])
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let title = card.staticTexts["振り返りの画面を日曜の夜に開ける"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let resting = settledFrame(of: title)
        let cancel = app.buttons["キャンセル"]

        // 2 番目の選択肢（問題あり）を数字キーで選ぶ。親の onKeyPress に届くよう typeKey で打つ
        app.typeKey("2", modifierFlags: [])
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { isHeldDownLeft(title, from: resting) }, "\(title.frame) / \(resting)")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil { isResting(title, at: resting) }, "\(title.frame) / \(resting)")

        card.buttons["問題あり（自由回答・左下へスワイプ）"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { isHeldDownLeft(title, from: resting) }, "\(title.frame) / \(resting)")

        let bar = app.navigationBars["問題あり"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bar.press(forDuration: 0.05, thenDragTo: bar.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntil { isResting(title, at: resting) }, "\(title.frame) / \(resting)")
    }

    /// 条件が満たされるまで待つ（カードはばねで動くので、落ち着くまで少し待つ）
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return condition()
    }

    /// 動きが止まった後の枠（開いた直後は、山札から札を引いて表に返す動きがある）
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.2)
            let frame = element.frame
            if abs(frame.minX - last.minX) < 0.5, abs(frame.minY - last.minY) < 0.5 {
                return frame
            }
            last = frame
        }
        return last
    }

    /// 札の中の題が左下へ、決まる距離くらい動いた所にある（飛んだときは画面の外まで動く）。
    /// 札の枠（`deckCard.top`）は表に返す演出の分だけ広く札と一緒に動かないので、札の中の題で測る。
    /// 下の部分はシートに隠れて枠から切られることがあるので、左上の角で測る。傾くので幅を持たせる
    @MainActor
    private func isHeldDownLeft(_ title: XCUIElement, from resting: CGRect) -> Bool {
        let moved = CGVector(dx: title.frame.minX - resting.minX, dy: title.frame.minY - resting.minY)
        return (-180 ... -40).contains(moved.dx) && (20...150).contains(moved.dy)
    }

    @MainActor
    private func isResting(_ title: XCUIElement, at resting: CGRect) -> Bool {
        abs(title.frame.minX - resting.minX) < 4 && abs(title.frame.minY - resting.minY) < 4
    }

    #if os(iOS)
    /// 自由記述のカードでは、キーボードの上の「完了」と、入力欄より上を叩くことでキーボードを閉じられる
    @MainActor
    func testFreeTextCardClosesKeyboard() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "deck:questions:habit-export"], reactionDelay: 600)
        let card = app.otherElements["deckCard.top"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        // Q2 に答えて、自由記述の Q3 を前に出す
        card.buttons["共有シートだけ（左下へスワイプ）"].tap()
        let title = card.staticTexts["ファイル名の決まり"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let field = card.descendants(matching: .any)["deckCard.freeText"]
        let keyboard = app.keyboards.firstMatch

        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))

        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    }
    #endif

    /// 進行中・Mac・リポジトリのタブを開ける
    @MainActor
    func testTabsOpen() {
        let app = launch(["-demoScenario", "standard"])
        XCTAssertTrue(app.tabBars.buttons["進行中"].waitForExistence(timeout: 10))
        app.tabBars.buttons["進行中"].tap()
        XCTAssertTrue(app.staticTexts["あなた待ち · 5"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Mac"].tap()
        XCTAssertTrue(app.staticTexts["Mac mini"].waitForExistence(timeout: 5))
        app.tabBars.buttons["リポジトリ"].tap()
        XCTAssertTrue(app.staticTexts["習慣ログ"].waitForExistence(timeout: 5))
    }

    /// 依頼は、送っている間は送るボタンを押せず、送れたら送った依頼（司令塔が受け取る前の epic）へ移り、同期待ちの小さな印を出す。
    /// 同じ依頼を続けて送ろうとすると、送る前に確かめる
    @MainActor
    func testRequestShowsProgressAndConfirmsDuplicate() {
        // CI の Simulator は 1 回の確かめに 1 秒以上かかるので、送っている間を長めにとる。
        // テストの間は司令塔の受け取りを遅らせ、同期待ちのままにする（受け取りが遅いと知らせる 3 分より短くする）
        let app = launch(["-demoScenario", "standard", "-demoSendDelay", "8", "-demoReceiptDelay", "120"])
        fillRequest(in: app)
        app.buttons["送る"].firstMatch.tap()
        // シートの一番上の行か、送るボタンの代わりの進み具合のどちらか
        let sending = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "送っています")).firstMatch
        XCTAssertTrue(sending.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["送る"].exists)

        XCTAssertTrue(app.staticTexts["メモ並べ替え"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(syncBadge(in: app).waitForExistence(timeout: 5))

        app.tabBars.buttons["あなたの番"].tap()
        fillRequest(in: app)
        app.buttons["送る"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["さきほど同じ依頼を送りました"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["もう一度送る"].exists)
    }

    /// 新しい依頼を開いて、献立メモへの「メモ並べ替え」を書く
    @MainActor
    private func fillRequest(in app: XCUIApplication) {
        let plus = app.buttons["新しい依頼"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        // メニューの選択は、名前に今の値が続いたボタンになる（例「アプリ, 選んでください」）
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "アプリ")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["献立メモ"].firstMatch.tap()
        let summary = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "要約")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        // 押した直後はまだフォーカスが移っていないことがあり、そのまま打つと「has keyboard focus」で落ちる。移るまで待ち、移らなければ押し直す
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        if XCTWaiter.wait(for: [expectation(for: focused, evaluatedWith: summary)], timeout: 3) != .completed {
            summary.tap()
            wait(for: [expectation(for: focused, evaluatedWith: summary)], timeout: 5)
        }
        summary.typeText("メモ並べ替え")
    }
}

// MARK: - 押したらすぐ済んだ形にする

extension ClientUITests {
    /// 最終 PR の残りをまとめて OK にすると、送り終える前からすぐ OK の形になり（ボタンは消える）、同期待ちの小さな印だけを出す。
    /// 反映中の行は出さない。司令塔が受け付けたら印は消える
    @MainActor
    func testAcceptAllShowsDoneAtOnceAndSyncsLater() {
        let app = launch([
            "-demoScenario", "standard", "-demoOpen", "final:tsundoku-search", "-demoSendDelay", "5", "-demoReceiptDelay", "3"
        ])
        let acceptAll = app.buttons["残りをまとめて OK…"]
        XCTAssertTrue(scrollUntilExists(acceptAll, in: app))
        // ボタンが下のマージの帯に隠れないよう、一覧の終わりまで送る
        for _ in 0..<2 {
            app.collectionViews.firstMatch.swipeUp()
        }
        acceptAll.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "件をまとめて OK")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // 送っている間（5 秒）から、残りの判断が OK の形になる
        let badge = syncBadge(in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        XCTAssertFalse(acceptAll.exists)
        XCTAssertFalse(app.descendants(matching: .any)["reflection-status"].exists)
        XCTAssertFalse(app.staticTexts["反映中"].exists)
        // 送り終えて司令塔が受け付けたら（受け付けの記録を軽く確かめて読み直す）、印は消える
        let synced = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: synced, evaluatedWith: badge)], timeout: Self.syncTimeout), .completed)
    }

    /// 同期待ちの印が消えるのを待つ上限。手元ではおよそ 10 秒（送る 5 秒・受け付け 3 秒・確かめの間隔）で消える。
    /// CI の Simulator は負荷が高く、アプリが 40 秒近く応えないことがあった（#1006）ので、CI の遅さに合わせて長くとる
    private static let syncTimeout: TimeInterval = 90

    /// 同期待ちの小さな印
    @MainActor
    private func syncBadge(in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ AND label == %@", "reflection-badge", "同期待ち")
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }
}

// MARK: - organization ごとに分けて並べる

extension ClientUITests {
    /// 依頼のシートのアプリのメニューは organization ごとの見出しで分かれ、選ぶと、選んだアプリの下に organization 付きの名前が出る
    @MainActor
    func testRequestPickerGroupsRepositoriesByOwner() {
        let app = launch(["-demoScenario", "standard"])
        let plus = app.buttons["新しい依頼"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "アプリ")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let first = app.staticTexts["demo-studio"]
        let second = app.staticTexts["kurashi-apps"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        // kurashi-apps のアプリは、kurashi-apps の見出しの下に並ぶ
        let item = app.buttons["積読リスト"].firstMatch
        XCTAssertTrue(item.exists)
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        XCTAssertGreaterThan(item.frame.minY, second.frame.minY)
        item.tap()
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "kurashi-apps/tsundoku-ios"))
            .firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
    }

    /// リポジトリのタブは organization ごとの節に分かれ、節の見出しに organization の名前が出る（名前順）
    @MainActor
    func testRepositoriesAreGroupedByOwner() {
        let app = launch(["-demoScenario", "standard", "-demoOpen", "section:repositories"])
        let first = app.staticTexts["demo-studio"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let second = app.staticTexts["kurashi-apps"]
        XCTAssertTrue(scrollUntilExists(second, in: app))
        let row = app.staticTexts["家事シェア"]
        XCTAssertTrue(scrollUntilExists(row, in: app))
        XCTAssertGreaterThan(row.frame.minY, second.frame.minY)
        // 見出しの持ち主は大文字にしない（GitHub の名前は書かれたとおりに出す）
        XCTAssertFalse(app.staticTexts["KURASHI-APPS"].exists)
    }
}

// MARK: - 進行中

extension ClientUITests {
    /// 進行中の終わったものは新しい 10 件だけを出し、それより前のものは「すべて見る」の画面で見返せる
    @MainActor
    func testFinishedEpicsShowRecentOnesAndAll() {
        let app = launch(["-demoScenario", "manyFinished"])
        XCTAssertTrue(app.tabBars.buttons["進行中"].waitForExistence(timeout: 10))
        app.tabBars.buttons["進行中"].tap()
        let showAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "すべて見る")).firstMatch
        XCTAssertTrue(scrollUntilExists(showAll, in: app, maxSwipes: 8))
        // 一番前に終わったもの（13 件のうち 13 番目）は、進行中には出さない
        let oldest = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "家事にかかった時間")).firstMatch
        XCTAssertFalse(oldest.exists)
        showAll.tap()
        XCTAssertTrue(app.navigationBars["終わったもの"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilExists(oldest, in: app, maxSwipes: 8))
    }
}
