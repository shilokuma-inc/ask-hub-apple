import SwiftUI

/// 札の動き（位置・回転・持ち上げ・影・奥行きの傾き・光）。
///
/// 奥行きのある動きと平らな動き（後ろの札・視差効果を減らすとき）で同じ形の modifier を重ね、値だけを変える
/// （形を変えると、一番上に出た札の中身が作り直され、中の状態が消えるため）。平らな動きは、これまでと同じく下の真ん中を軸に回して動かすだけ。
/// 離した後の動き（`SwipeCardMotion.thrown`）はアニメーションを使わず、時刻ごとに位置と速さを計算して描く
struct SwipeMotionEffect: ViewModifier {
    /// 奥行きのある動きにするか（一番上の札で、視差効果を減らしていないとき）
    let usesDepth: Bool
    let isInteractive: Bool
    let offset: CGSize
    let motion: SwipeCardMotion
    let drag: SwipeDragState
    let directions: [SwipeDirection]

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !(usesDepth && motion.isAnimating))) { context in
            moved(content, at: context.date)
        }
    }

    private func moved(_ content: Content, at date: Date) -> some View {
        let current = usesDepth ? motion.offset(at: date, resting: offset) : offset
        let pose = usesDepth ? SwipePose(offset: current, velocity: motion.velocity(at: date), grab: motion.grab) : .flat
        let lift: CGFloat = usesDepth && motion.isHeld ? 1 : 0
        let shadow = shadow(lift: lift)
        return content
            .overlay {
                SwipeLight(lean: pose.lean, lift: lift, drag: drag, directions: directions)
                    .opacity(usesDepth ? 1 : 0)
            }
            // 向かう先の縁が奥へ下がる。軸はつかんだ所を通す（指の下の点は動かない）
            .rotation3DEffect(
                pose.tilt,
                axis: (x: pose.axis.dx, y: pose.axis.dy, z: 0),
                anchor: motion.grab,
                perspective: SwipeFeelMotion.perspective
            )
            .scaleEffect(1 + (SwipeFeelMotion.liftScale - 1) * lift, anchor: motion.grab)
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
            // 触れたら持ち上げ、離したら置く（平らな動きでは `lift` が変わらないので、ほかの動きに影響しない）
            .animation(SwipeFeelMotion.lift, value: lift)
            .rotationEffect(pose.rotation, anchor: motion.grab)
            // 決まる量を超えたら、向かう先へ少し吸い付く
            .offset(usesDepth ? detentPull : .zero)
            .animation(SwipeFeelMotion.detent, value: usesDepth ? detentPull : .zero)
            .offset(current)
            .rotationEffect(usesDepth ? .zero : .degrees(Double(offset.width) / 26), anchor: .bottom)
    }

    private var detentPull: CGSize {
        guard drag.isPastThreshold, let candidate = drag.candidate, directions.indices.contains(candidate) else {
            return .zero
        }
        let unit = directions[candidate].unit
        return CGSize(width: unit.dx * SwipeFeelMotion.detentPull, height: unit.dy * SwipeFeelMotion.detentPull)
    }

    private func shadow(lift: CGFloat) -> SwipeShadow {
        guard isInteractive else {
            return .behind
        }
        return SwipeFeelMotion.restingShadow.mixed(with: SwipeFeelMotion.liftedShadow, by: lift)
    }
}

/// 札の面に映る光。手前に起きた縁（傾きと反対側）に白い照り返しが映り、向かう先の角からその方向の色の光がにじむ。
/// 照り返しは重ねる混ぜ方にするので、白い地の上では目立たず、色の付いた所（上の帯・選択肢の行）だけが明るくなる
private struct SwipeLight: View {
    /// 傾いた向きと強さ（大きさは 0〜1）
    let lean: CGVector
    let lift: CGFloat
    let drag: SwipeDragState
    let directions: [SwipeDirection]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
        ZStack {
            ForEach(Array(directions.enumerated()), id: \.offset) { index, direction in
                let strength = drag.candidate == index ? drag.progress : 0
                // 向かう先の角は画面の外に出やすいので、色は札の真ん中のあたりまで届かせる
                EllipticalGradient(
                    colors: [direction.tint.opacity(0.24 * strength), direction.tint.opacity(0)],
                    center: direction.anchor,
                    startRadiusFraction: 0,
                    endRadiusFraction: 1.25
                )
                // 縁は、向かう先の角から反対の角へ薄れていく。決まる量を超えると、札の太い縁（`thresholdEdge`）に替わる
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: direction.edge.opacity(0.85 * strength), location: 0),
                            .init(color: direction.edge.opacity(0.3 * strength), location: 0.6),
                            .init(color: direction.edge.opacity(0), location: 1)
                        ],
                        startPoint: direction.anchor,
                        endPoint: UnitPoint(x: 1 - direction.anchor.x, y: 1 - direction.anchor.y)
                    ),
                    lineWidth: 2
                )
            }
            EllipticalGradient(
                colors: [.white.opacity(glare), .white.opacity(0)],
                center: glareCenter,
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )
            .blendMode(.overlay)
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 持ち上げると上から淡く照らされ、傾けるほど手前の縁に強く映る
    private var glare: Double {
        let strength = 0.12 * Double(lift) + 0.34 * Double(hypot(lean.dx, lean.dy))
        return min(strength, 0.4) * (colorScheme == .dark ? 0.6 : 1)
    }

    private var glareCenter: UnitPoint {
        UnitPoint(x: 0.5 - 0.5 * lean.dx, y: 0.35 - 0.5 * lean.dy)
    }
}
