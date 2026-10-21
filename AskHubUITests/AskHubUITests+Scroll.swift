import XCTest

extension AskHubUITests {
    /// Form は画面の外の行を作らないので、要素が押せる位置に出るまで上下にスクロールする。
    /// 回答の画面は添付欄のぶん長いので、下へ探してから上へ戻って探す
    @MainActor
    func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews.firstMatch
        for direction in [true, false] {
            for _ in 0..<6 {
                if element.exists && element.isHittable {
                    return
                }
                if direction {
                    list.swipeUp(velocity: .slow)
                } else {
                    list.swipeDown(velocity: .slow)
                }
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) が画面に出ない", file: file, line: line)
    }
}
