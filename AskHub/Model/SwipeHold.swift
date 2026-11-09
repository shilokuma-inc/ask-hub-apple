import CoreGraphics

/// 自由回答（送る前に文を書く選択肢）に決めたときの扱い。カードを飛ばさずに、その方向の決まる位置で止めて文を書くシートを出す。
/// シートで送ったら、ほかの選択肢と同じように飛ばしてから送り、送らずに閉じたら元の位置に戻す（ユーザーの決定。2026-11-04）
struct SwipeHold: Equatable {
    private enum Phase: Equatable {
        case idle
        /// カードを止めて、文を書くシートを出している
        case holding
        /// シートで送った。シートが閉じたらカードを飛ばし、飛び終わったら送る
        case sent(String)
    }

    private var phase = Phase.idle
    /// 変わったら、止めたカードを飛ばす
    private(set) var releaseToken = 0

    /// 止める選択肢（`choices` の添字）。送る前に文を書いてもらう選択肢
    static func heldChoices(_ choices: [DeckCard.Choice]) -> Set<Int> {
        Set(choices.indices.filter { choices[$0].asksText })
    }

    /// 止める位置。その方向へ、ちょうど決まる距離だけ動かした所
    static func offset(for direction: SwipeDirection) -> CGSize {
        CGSize(width: direction.unit.dx * SwipeLayout.commitDistance, height: direction.unit.dy * SwipeLayout.commitDistance)
    }

    /// カードを止めて、シートを出した
    mutating func start() {
        phase = .holding
    }

    /// シートで送ったとき。カードを止めていなければ（説明を求めるなど）false を返すので、その場で送る
    mutating func send(_ text: String) -> Bool {
        guard phase == .holding else {
            return false
        }
        phase = .sent(text)
        return true
    }

    /// シートが閉じたとき。送ったならカードを飛ばす。送らずに閉じたなら止めるのをやめ、カードを元の位置に戻すので true を返す
    mutating func sheetDismissed() -> Bool {
        switch phase {
        case .idle:
            return false

        case .holding:
            phase = .idle
            return true

        case .sent:
            releaseToken += 1
            return false
        }
    }

    /// 止めたカードが飛び終わったとき。シートで書いた文（止めていなければ nil）
    mutating func finish() -> String? {
        guard case .sent(let text) = phase else {
            return nil
        }
        phase = .idle
        return text
    }
}
