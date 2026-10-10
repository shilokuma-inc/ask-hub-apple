import Foundation

/// 仮決め一覧（`decision-log`）のコメントに置く目印。詳細は `docs/protocol.md` の「仮決め一覧」を参照。
/// ループと人間は同じアカウントでコメントするため、author ではなくこの目印でループ・オーケストレーターのコメントを見分ける
public enum DecisionLogMarker {
    /// ループが仮決め一覧への指示に返信するときに置く目印
    public static let reply = "<!-- ask-hub:decision-reply -->"
    /// オーケストレーターが閉じるときのコメントに置く目印
    public static let close = "<!-- ask-hub:decision-close -->"
    /// どちらかの目印を含めば、処理済みの判定で返信として扱われる
    public static let all = [reply, close]
}
