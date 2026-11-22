import Foundation

/// 人がする作業の Secrets に入れる値の入力。入れ始めたときのゴールの版を覚え、入れている間に版が変わったら値を消す
/// （直したゴールでは、同じ作業でも Secrets の名前が変わっているかもしれないため。消したら、見直してから入れ直してもらう）
struct SecretEntry: Equatable {
    /// 入れた値（送ったら・版が変わったら消す。端末の外には出さない）
    private(set) var value = ""
    /// 入れ始めたときのゴールの版。何も入れていなければ nil
    private(set) var goalVersion: Int?

    /// 値を入れる。空から入れ始めたときに、今のゴールの版を覚える
    mutating func edit(_ text: String, goalVersion current: Int?) {
        if value.isEmpty || goalVersion == nil { goalVersion = current }
        value = text
        if text.isEmpty { goalVersion = nil }
    }

    /// ゴールの版が変わった。入れていた値を消したら true
    mutating func goalChanged(to version: Int?) -> Bool {
        guard !value.isEmpty, version != goalVersion else { return false }
        clear()
        return true
    }

    mutating func clear() {
        value = ""
        goalVersion = nil
    }
}
