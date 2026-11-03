import SwiftUI

/// 山札と捨て札の時間とばねと寸法。動画を見ながら、気持ちよさを優先して決めた値
enum DrawMotion {
    /// 山札の一番上の札を、前の札からどれだけ下にずらすか
    static let pileBase: CGFloat = 5
    /// 山札の 1 枚ごとのずれ（厚み）
    static let pileStep: CGFloat = 3
    /// 縁だけを描く札の枚数の上限（山札の上の 2 枚は札そのもの）
    static let maxEdges = 5
    /// 開いてから、前の札を山札から引いて表に返すまで
    static let dealDelay = Duration.milliseconds(350)

    /// 引き出すときに横へずらす幅・持ち上げる高さ・傾き（真ん中で最大）
    static let pullWidth: CGFloat = 42
    static let pullRise: CGFloat = 6
    static let pullTilt = 5.0

    /// 引き出して前に置く。少し行き過ぎて止まる
    static let pullOut = Animation.spring(duration: 0.55, bounce: 0.2)
    /// 山札に戻す（取り消し・あとで）
    static let pullBack = Animation.spring(duration: 0.4, bounce: 0.05)
    /// 視差効果を減らすとき
    static let fade = Animation.easeInOut(duration: 0.2)

    static func pull(drawn: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion {
            return fade
        }
        return drawn ? pullOut : pullBack
    }

    /// 捨て札の小さな札の大きさ
    static let miniSize = CGSize(width: 28, height: 40)
    /// 捨て札の束の位置（前の札の角から内側へ・上へ）
    static let cornerInset: CGFloat = 30
    static let cornerLift: CGFloat = 8
    /// 「済み N」を束の真ん中からどれだけ上げるか（前の札の後ろに隠れないように）
    static let countLift: CGFloat = -10
    /// 「済み N」と束の間
    static let countGap: CGFloat = 6
    /// 捨て札の札が、束の手前のどれだけ遠くから滑り込むか
    static let dropReach: CGFloat = 26
    /// 捨て札に落ちて重なる。少し弾む
    static let dropIn = Animation.spring(duration: 0.42, bounce: 0.3).delay(0.04)

    static func drop(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : dropIn
    }

    /// 取り消したときに、捨て札から前に戻る
    static let returnFromDiscard = Animation.spring(duration: 0.5, bounce: 0.14)

    /// 最後の札を置いてから束を集め始めるまで（捨て札に落ちるのを見せてから）
    static let gatherDelay = Duration.milliseconds(350)
    /// 集め始めてから「N 件 答えました」・空の画面の文言を出すまで（秒）。「済み N」は札が束に落ちてから出す
    static let labelReveal = 0.4
    static let emptyReveal = 0.55
    static let countReveal = 0.25
    /// 集めた束の大きさ。真ん中から上へずらし、下に一言と空の画面の文言を置く
    static let gatherScale: CGFloat = 2.4
    /// そろえた束の 1 枚ごとのずれ（束の大きさの中で。拡大すると厚みに見える）
    static let gatheredStep: CGFloat = 1.6
    static let finishSpace: CGFloat = 190
    static var gatherCenter: CGFloat { -finishSpace / 2 }
    static var finishLabelTop: CGFloat { gatherCenter + miniSize.height * gatherScale / 2 + 16 }
    /// 「最後の 1 枚」を前の札の下の縁からどれだけ下に出すか
    static let lastNoteGap: CGFloat = 20

    static func gather(reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : .spring(duration: 0.6, bounce: 0.12)
    }

    /// 束をそろえる（トントンと 2 回、軽く机に打つ）
    @KeyframesBuilder<CGFloat> static var squareKeyframes: some Keyframes<CGFloat> {
        KeyframeTrack {
            MoveKeyframe(0)
            CubicKeyframe(-8, duration: 0.09)
            CubicKeyframe(0, duration: 0.08)
            CubicKeyframe(-4, duration: 0.08)
            CubicKeyframe(0, duration: 0.08)
        }
    }

    /// 束が机に当たる時刻（前の当たりからの間）。`squareKeyframes` の 0 に戻るところに合わせる
    static let tapDelays: [Duration] = [.milliseconds(170), .milliseconds(160)]
}

/// 捨て札の 1 枚
struct DiscardEntry: Identifiable, Equatable {
    let id: DeckCard.ID
    /// 答えた方向（おまかせ・説明を求めるなど、スワイプや選択肢を通らずに送ったときは nil）
    let direction: SwipeDirection?
    /// 何枚目に置いたか。傾きとずれを決める
    let order: Int

    /// 投げて重ねた束らしく、1 枚ずつ違う向きに傾ける（決まった並びで、揺れない）
    var tilt: Double {
        [-9, 7, -4, 10, -7, 3, -11, 6][order % 8]
    }

    var jitter: CGSize {
        let steps: [CGFloat] = [0, 1.5, -1, 2, -2, 0.5, -1.5, 1]
        return CGSize(width: steps[order % 8], height: steps[(order + 3) % 8])
    }
}

/// 捨て札の束。新しい札は飛ばした向きの動きのまま落ちてきて重なる。集めたときは傾きをそろえて 1 つの束にする
struct DiscardPile: View {
    let entries: [DiscardEntry]
    let isGathered: Bool
    let reduceMotion: Bool

    /// 描く枚数の上限（下の札は隠れて見えないので）
    private static let shown = 8

    var body: some View {
        let visible = Array(entries.suffix(Self.shown))
        ZStack {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                DiscardMiniCard(direction: entry.direction, mark: index == visible.count - 1 ? mark(for: entry) : nil)
                    .rotationEffect(.degrees(isGathered ? 0 : entry.tilt))
                    .offset(isGathered ? CGSize(width: 0, height: -CGFloat(index) * DrawMotion.gatheredStep) : entry.jitter)
                    // そろえるときは、上の札ほど少し遅れて重なる
                    .animation(
                        reduceMotion ? nil : DrawMotion.gather(reduceMotion: false).delay(Double(index) * 0.03),
                        value: isGathered
                    )
                    .transition(drop(entry))
            }
        }
        .frame(width: DrawMotion.miniSize.width, height: DrawMotion.miniSize.height)
        .accessibilityHidden(true)
    }

    /// 一番上の札の記号。答えた方向の矢印にし、そろえた束にはチェックを付ける
    private func mark(for entry: DiscardEntry) -> String {
        if isGathered {
            return "checkmark"
        }
        return entry.direction?.systemImage ?? "checkmark"
    }

    private func drop(_ entry: DiscardEntry) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        // 飛ばした向きの動きのまま、束の手前から滑り込む（方向が無いときは上から落ちる）
        let unit = entry.direction?.unit ?? CGVector(dx: 0, dy: 1)
        return .asymmetric(
            insertion: .modifier(
                active: DiscardLanding(
                    offset: CGSize(width: -unit.dx * DrawMotion.dropReach, height: -unit.dy * DrawMotion.dropReach),
                    scale: 1.6,
                    rotation: entry.tilt * 2,
                    opacity: 0
                ),
                identity: DiscardLanding(offset: .zero, scale: 1, rotation: 0, opacity: 1)
            ),
            removal: .opacity
        )
    }
}

struct DiscardLanding: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let rotation: Double
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .opacity(opacity)
    }
}

/// 捨て札の小さな札。表向きで、答えた方向の色の縁を残す。一番上の札には方向の矢印を付ける
struct DiscardMiniCard: View {
    let direction: SwipeDirection?
    /// 真ん中に付ける記号（SF Symbols の名前）。nil なら付けない
    let mark: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let tint = direction?.tint ?? Theme.Tone.slate
        let edge = direction?.edge ?? Theme.Tone.slate
        ZStack {
            shape.fill(.background)
            shape.fill(tint.opacity(SwipeIntensity.rest))
            shape.inset(by: 2.5).strokeBorder(.white.opacity(0.8), lineWidth: 0.75)
            if let mark {
                Image(systemName: mark)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(edge)
            }
        }
        .overlay(shape.strokeBorder(edge, lineWidth: 1.5))
        .frame(width: DrawMotion.miniSize.width, height: DrawMotion.miniSize.height)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

/// 捨て札の枚数
struct DiscardCount: View {
    let count: Int

    var body: some View {
        Text("済み \(count)")
            .appFont(.caption, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText(value: Double(count)))
            .fixedSize()
    }
}

/// 最後の 1 枚になったら、前の札の下に出す
struct LastCardNote: View {
    var body: some View {
        Label("最後の 1 枚", systemImage: "sparkles")
            .appFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.background.opacity(0.7), in: .capsule)
    }
}

/// 全部答えて束をそろえたときの一言
struct DrawFinishLabel: View {
    let count: Int

    var body: some View {
        Text("\(count) 件 答えました")
            .appFont(.headline, weight: .bold)
    }
}
