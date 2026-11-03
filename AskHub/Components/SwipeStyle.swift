import SwiftUI

/// スワイプの方向ごとの色。行き先は文字ではなく、カードの後ろの背景の色で示す（ユーザーの決定。2026-11-03）
extension SwipeDirection {
    /// パステルの色（↗ 緑・↖ 青・↙ 橙・↘ 紫）。濃さは使う側の不透明度で決め、ビビッドにしない
    var tint: Color {
        switch self {
        case .upRight: Color(red: 0.28, green: 0.78, blue: 0.56)
        case .upLeft: Color(red: 0.36, green: 0.63, blue: 1.0)
        case .downLeft: Color(red: 1.0, green: 0.63, blue: 0.40)
        case .downRight: Color(red: 0.65, green: 0.55, blue: 0.98)
        }
    }

    /// 決まるときの枠の色（方向の色を少し濃くしたもの）
    var edge: Color {
        tint.mix(with: .black, by: 0.12)
    }

    /// 背景のグラデーションがにじみ出る角
    var anchor: UnitPoint {
        switch self {
        case .upRight: .topTrailing
        case .upLeft: .topLeading
        case .downLeft: .bottomLeading
        case .downRight: .bottomTrailing
        }
    }
}

/// いまどの選択肢に向かって、どこまで動かしたか。背景とカードの中の選択肢で共有する
struct SwipeDragState: Equatable {
    var candidate: Int?
    /// 0〜1。1 で決まる
    var progress: Double = 0

    var isPastThreshold: Bool { candidate != nil && progress >= 1 }
}

/// 濃さの決まり。同じ方向は、選択肢の行・矢印・背景の角でいつも同じ濃さの同じ色にする（ユーザーの決定。2026-11-03）。
/// 動かすほど少し濃くなるが、上限でもパステルのまま
enum SwipeIntensity {
    static let rest = 0.30
    static let max = 0.55

    static func opacity(index: Int, drag: SwipeDragState) -> Double {
        guard let candidate = drag.candidate else {
            return rest
        }
        if index == candidate {
            return rest + (max - rest) * drag.progress
        }
        return rest * (1 - 0.5 * drag.progress)
    }
}

/// カードの後ろの背景。使う方向の角から、その方向の色がにじむ
struct SwipeBackdrop: View {
    let directions: [SwipeDirection]
    let drag: SwipeDragState

    var body: some View {
        GeometryReader { proxy in
            let reach = hypot(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(Array(directions.enumerated()), id: \.offset) { index, direction in
                    let isCandidate = drag.candidate == index
                    RadialGradient(
                        colors: [
                            direction.tint.opacity(SwipeIntensity.opacity(index: index, drag: drag)),
                            direction.tint.opacity(0)
                        ],
                        center: direction.anchor,
                        startRadius: 0,
                        endRadius: reach * (0.62 + (isCandidate ? 0.2 * drag.progress : 0))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// カードの中の選択肢の 1 行。方向の色の背景と、方向の矢印を付ける
struct SwipeChoiceRow: View {
    let choice: DeckCard.Choice
    let direction: SwipeDirection
    let index: Int
    let drag: SwipeDragState
    var keyHint: String?

    /// 向かっている行の枠の太さ。動かすほど太くし、決まる量を超えたらはっきり太くする（ユーザーの要望）
    private var borderWidth: CGFloat {
        guard drag.candidate == index else {
            return 0
        }
        return drag.isPastThreshold ? 3 : 1 + 1.5 * drag.progress
    }

    var body: some View {
        let color = direction.tint.opacity(SwipeIntensity.opacity(index: index, drag: drag))
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: direction.systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(color, in: .circle)
                .overlay(Circle().strokeBorder(.background.opacity(0.6), lineWidth: 1))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 推奨は太字にして、ひと目で分かるようにする（ユーザーの要望）
                    Text(choice.label)
                        .font(.subheadline.weight(choice.isRecommended ? .bold : .regular))
                    if choice.isRecommended {
                        RecommendedBadge(tint: direction.tint)
                    }
                }
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let note = choice.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let keyHint {
                Text(keyHint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: shape)
        .overlay(shape.strokeBorder(direction.edge, lineWidth: borderWidth))
        .contentShape(.rect(cornerRadius: 12))
        .animation(.snappy(duration: 0.15), value: drag.isPastThreshold)
    }
}

/// 推奨の札。地を方向の色の濃いめにし、白い太字にして、選択肢の文字と見分けやすくする（ユーザーの要望）
struct RecommendedBadge: View {
    let tint: Color

    var body: some View {
        Label("推奨", systemImage: "star.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.mix(with: .black, by: 0.18), in: .capsule)
            .accessibilityLabel("推奨")
    }
}
