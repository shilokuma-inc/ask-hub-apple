import XCTest

// MARK: - メニュー（Picker の menu）の項目を選ぶ

/// CI の Simulator では、開き切って静止したメニューでも、XCTest が項目を押す位置を計算できない（`Activation point invalid`）・
/// 押しても選ばれない・画面に出ている項目や見出しの枠が `inf` になることが、開いている間ずっと続くことがある（#1245）。
/// 手元では再現しない。メニューの項目は `tap()` で押さず、ここで選ぶ
extension ClientUITests {
    /// メニューを開き直す回数の上限
    private static let menuAttempts = 3

    /// メニューの名前（例「アプリ」）のボタンを押してメニューを開き、項目を選ぶ。選べたかを返す。
    /// 押せる（`isHittable`）まで待ってから枠の中央を座標で押し、選んだ値がメニューのボタンの名前に出たかで確かめる。出なければ閉じて開き直す
    @MainActor
    func choose(_ item: String, inMenu name: String, in app: XCUIApplication) -> Bool {
        let option = app.buttons[item].firstMatch
        // 選んだ後のメニューのボタンの名前は「<名前>, <値>」（端末の言語によって区切りが「、」になる）
        let chosen = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", name, item)).firstMatch
        for attempt in 1...Self.menuAttempts {
            if openMenu(name, showing: [option], in: app) {
                press(option, in: app)
                if chosen.waitForExistence(timeout: 5) {
                    return true
                }
            }
            XCTContext.runActivity(named: "「\(item)」を選べなかったので、メニューを閉じて開き直す（\(attempt) 回目）") { _ in
                closeMenu(showing: option, in: app)
            }
        }
        return false
    }

    /// メニューを開き、`elements`（項目・見出し）の枠をすべて読めたら、その枠を返す。読めなければ閉じて開き直し、それでも読めなければ nil。
    /// 開いたメニューはそのままにする（続けて `choose` で選べる）
    @MainActor
    func menuFrames(of elements: [XCUIElement], inMenu name: String, in app: XCUIApplication) -> [CGRect]? {
        for attempt in 1...Self.menuAttempts {
            if openMenu(name, showing: elements, in: app), waitUntilFramesAreReadable(elements) {
                return elements.map { $0.frame }
            }
            XCTContext.runActivity(named: "メニューの枠を読めなかったので、閉じて開き直す（\(attempt) 回目）") { _ in
                elements.first.map { closeMenu(showing: $0, in: app) }
            }
        }
        return nil
    }

    /// メニューを開き、`elements` が出るまで待つ。もう開いていれば押さない
    @MainActor
    private func openMenu(_ name: String, showing elements: [XCUIElement], in app: XCUIApplication) -> Bool {
        if elements.allSatisfy({ $0.exists }) {
            return true
        }
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        guard menu.waitForExistence(timeout: 5) else {
            return false
        }
        menu.tap()
        return elements.allSatisfy { $0.waitForExistence(timeout: 5) }
    }

    /// 項目を押す。押せる（`isHittable`）まで待ち、枠の中央を座標で押す。
    /// `tap()` は押す位置を計算できないとその場でテストを落とすので使わない（押せないままでも、枠が読めていれば座標で押せる）
    @MainActor
    private func press(_ option: XCUIElement, in app: XCUIApplication) {
        let hittable = waitForPredicate("isHittable == true", on: option, timeout: 5)
        guard waitUntilFramesAreReadable([option]) else {
            return
        }
        let frame = option.frame
        let name = hittable ? "「\(option.label)」を押す" : "「\(option.label)」の押す位置を計算できないので、枠 \(frame) の中央を座標で押す"
        XCTContext.runActivity(named: name) { _ in
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        }
    }

    /// 開いたメニューを、メニューの外（シートの題の辺り）を押して閉じる
    @MainActor
    private func closeMenu(showing option: XCUIElement, in app: XCUIApplication) {
        guard option.exists else {
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        _ = waitForPredicate("exists == false", on: option, timeout: 5)
    }

    /// 要素がすべてあり、枠を読める（`inf` でない）まで待つ
    @MainActor
    private func waitUntilFramesAreReadable(_ elements: [XCUIElement], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let readable = elements.allSatisfy { element in
                guard element.exists else {
                    return false
                }
                let frame = element.frame
                return frame.minX.isFinite && frame.minY.isFinite && !frame.isEmpty
            }
            if readable {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    /// 要素が条件を満たすまで待つ。満たさなくてもテストは落とさない
    @MainActor
    private func waitForPredicate(_ format: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
