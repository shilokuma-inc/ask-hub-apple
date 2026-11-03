import SwiftUI

/// 札の格。山札の縁の線と、表に返るときの演出の強さと色を、札の中身だけで決める。
///
/// カードゲームのレア度のように、ふつうの札は控えめに、先へ進める札は豪華に出し、慎重に決めてほしい札は祝わずに警告ふうに出す。
/// 同じ札はいつも同じ格で、ランダムな「当たり」は作らない
enum CardGrade: Equatable {
    /// ふつうの札
    case common
    /// 実機の確認（手元に端末が要る）
    case device
    /// 先へ進める札。ほかの質問がこの回答を待っているか、その epic のこの種類の札の最後の 1 枚（答えると質問がそろう・判断の確認が終わる）
    case key
    /// 慎重に決めてほしい札（セキュリティなど）。先へ進める札でも、こちらを先に決める
    case caution(Caution)

    /// - Parameter remaining: まだ答えていない札（飛び始めた札と、取り消しを待っている札は含めない）
    init(card: DeckCard, epic: Epic?, remaining: [DeckCard]) {
        if let caution = card.caution {
            self = .caution(caution)
            return
        }
        switch card.content {
        case .verification:
            self = .device

        case .question(let question):
            let questions = epic?.questions ?? []
            let isAwaited = questions.dependents(of: question).contains { !$0.isSettled }
            // ロック・説明待ち・見直し中の質問が残っていれば、答えても質問はそろわない
            let isStuck = questions.contains { $0.id != question.id && !$0.isSettled && !$0.isAnswerable }
            let isLast = !Self.hasSibling(of: card, in: remaining) && !isStuck
            self = isAwaited || isLast ? .key : .common

        case .decision(let decision):
            // 直している判断が残っていれば、答えても判断の確認は終わらない
            let isFixing = epic?.finalReview?.decisions.contains { $0.id != decision.id && !$0.isConfirmed && !$0.needsReview } ?? false
            self = !Self.hasSibling(of: card, in: remaining) && !isFixing ? .key : .common
        }
    }

    /// 同じ epic の同じ種類の札が、ほかに残っているか
    private static func hasSibling(of card: DeckCard, in remaining: [DeckCard]) -> Bool {
        remaining.contains { other in
            guard other.id != card.id, other.epicID == card.epicID else {
                return false
            }
            switch (other.content, card.content) {
            case (.question, .question), (.decision, .decision), (.verification, .verification):
                return true

            default:
                return false
            }
        }
    }
}

/// 格ごとの見た目。方向の色（緑・青・橙・紫）と重ならない金・ローズ・赤にし、パステルの濃さのまま
extension CardGrade {
    /// 後光と、札の面が光るときの色（ふつうの札は、白に近い淡い青紫。白では明るい背景に見えないため）
    var glow: Color {
        switch self {
        case .common: Color.rgb(0.80, 0.83, 1.0)
        case .device: Theme.Pastel.rose
        case .key: Theme.Pastel.butter
        case .caution: Color.rgb(1.0, 0.68, 0.66)
        }
    }

    /// 縁・きらめきの粒・裏の札の印の色（少し濃いパステル）
    var tone: Color {
        switch self {
        case .common: Color.rgb(0.66, 0.70, 0.90)
        case .device: Theme.Tone.rose
        case .key: Theme.Tone.butter
        case .caution: Color.rgb(0.92, 0.40, 0.42)
        }
    }

    /// 裏の札に出す印。色だけで意味を伝えないように、文字と記号でも書く（ふつうの札には出さない）
    var badge: (title: String, systemImage: String)? {
        switch self {
        case .common: nil
        case .device: ("実機で確かめる", "iphone")
        case .key: ("先へ進める", "key.fill")
        case .caution(let caution): (caution.label, caution.systemImage)
        }
    }

    /// 待っている間の裏の縁の光（0 で光らない）
    var restingRim: Double {
        switch self {
        case .common: 0
        case .device, .key: 0.75
        case .caution: 0.9
        }
    }

    /// 後光の筋の数（0 なら筋を出さない）
    var rayCount: Int {
        switch self {
        case .common, .caution: 0
        case .device: 10
        case .key: 16
        }
    }

    /// 返る瞬間にはじけるきらめきの粒の数（ふつうの札と警告は出さない）
    var sparkleCount: Int {
        switch self {
        case .common, .caution: 0
        case .device: 12
        case .key: 22
        }
    }

    /// 粒を虹の色にするか（いちばん豪華な、先へ進める札だけ）
    var hasRainbowSparkles: Bool {
        self == .key
    }

    /// 表に返るときに走る虹の帯の濃さ（警告は虹を出さず、斜めの縞が走る）
    var rainbowStrength: Double {
        switch self {
        case .common: 0.45
        case .device: 0.6
        case .key: 0.85
        case .caution: 0
        }
    }

    /// 表に返る瞬間の触覚の強さ
    var revealIntensity: Double {
        switch self {
        case .common: 0.45
        case .device: 0.8
        case .key, .caution: 1
        }
    }

    /// 返る前の溜め
    enum ChargeStyle {
        /// 溜めずにすぐ返す
        case none
        /// 持ち上がって震え、光をためる
        case lift
        /// 持ち上げず、縁が赤く脈打って横に小さく揺れる
        case alert
    }

    var chargeStyle: ChargeStyle {
        switch self {
        case .common: .none
        case .device, .key: .lift
        case .caution: .alert
        }
    }

    var isCaution: Bool {
        if case .caution = self {
            return true
        }
        return false
    }
}
