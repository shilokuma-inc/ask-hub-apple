import Foundation

/// 回答画面の「投稿したら、回答を確定してループを始める」の既定値（Discussion #244 の Q1）。設定画面で切り替える。
///
/// 秘密ではないので UserDefaults に保存する。保存していなければオン。
/// 回答画面のトグルは、画面を開いた時点のこの値から始まる（回答画面で切り替えても、この値は書き換えない）
enum LoopStartPreference {
    static let defaultsKey = "AskHubStartsLoopAfterPosting"
    static let defaultValue = true

    static func startsLoopAfterPosting(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? defaultValue
    }

    /// 保存した値を消して既定値に戻す。UI テストが前回の起動で切り替えた値に左右されないようにする
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
