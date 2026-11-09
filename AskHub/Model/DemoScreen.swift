import Foundation

/// デモのデータで描く、簡単な画面の絵（判断のカードの Before / After に使う）。
///
/// 本番では、ワーカーがデモモードのデータで撮ったスクショ（`Screenshot.stored`）を使う
struct DemoScreen: Hashable {
    var title: String
    /// ナビゲーションバーの右のボタン
    var toolbarItem: String?
    var toolbarItemHighlighted = false
    var elements: [Element]

    enum Element: Hashable {
        case search(highlighted: Bool)
        case section(String, highlighted: Bool)
        case row(String, detail: String?, highlighted: Bool)
    }
}
