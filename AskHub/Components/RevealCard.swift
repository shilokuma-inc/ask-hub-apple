import SwiftUI

/// 裏向きの札を、中身の格（`CardGrade`）に合わせた演出で表に返す。
///
/// - ふつうの札: 溜めずにすぐ返り、淡い虹の帯が 1 回走るだけ
/// - 実機の確認・先へ進める札: 前の札が飛んでいく間に溜め（持ち上がって震え、縁の光が強まり、返る向きと逆へ少し引く）を作り、
///   後光・きらめきの粒・虹の帯の中で返す。触覚は溜めの弱い 2 回から、返る瞬間の強い 1 回へ強まる
/// - 慎重に決めてほしい札: 祝わない。持ち上げずに横に小さく揺れ、縁が 2 回脈打ち、輪が広がり、虹の代わりに斜めの縞が走る。触覚は「警告」
///
/// 表と裏の 2 面を重ねて、90° を過ぎたところで見せる面を替える（裏の面はあらかじめ 180° 回し、文字が鏡写しにならないようにする）。
/// 「視差効果を減らす」が有効なら、溜め・揺れ・後光・粒・帯の走りをやめ、短いフェードで表にする
struct RevealCard<Front: View, Back: View>: View {
    /// 表を見せるか。表になるときは溜めてから返し、裏に戻るとき（取り消しなど）はすぐ戻す
    let isFaceUp: Bool
    /// めくる向き。1 で左の縁が手前に起きて右へ返り、-1 で右の縁が起きて左へ返る
    let direction: Double
    let grade: CardGrade
    @ViewBuilder let front: Front
    @ViewBuilder let back: Back

    /// 0 で表、1 で裏
    @State private var turn: Double
    /// 溜め（0 から 1）。持ち上げと縁の光の強さ
    @State private var charge = 0.0
    /// 溜めで、返る向きと逆へ引く量（0 から 1）
    @State private var windUp = 0.0
    /// 変わるたびに札が震える
    @State private var shakes = 0
    /// 変わるたびに札が横に小さく揺れる（警告の溜め）
    @State private var alerts = 0
    /// 変わるたびに、後光・粒・面の光が一巡する（溜めの間は待ってから始まる）
    @State private var bursts = 0
    @State private var pulse = RevealPulse()
    /// 表に返す・裏に戻すたびに増やす。古い溜めの続きを止める
    @State private var reveals = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(
        isFaceUp: Bool,
        direction: Double = 1,
        grade: CardGrade,
        @ViewBuilder front: () -> Front,
        @ViewBuilder back: () -> Back
    ) {
        self.isFaceUp = isFaceUp
        self.direction = direction
        self.grade = grade
        self.front = front()
        self.back = back()
        _turn = State(initialValue: isFaceUp ? 0 : 1)
    }

    var body: some View {
        let style = grade.chargeStyle
        let hold = reduceMotion || style == .none ? 0 : RevealMotion.chargeDuration
        // 警告の溜めは持ち上げず、返る向きと逆へも引かない（祝う動きに見せない）
        let liftFactor: CGFloat = style == .alert ? 0 : 1
        // 格ごとの違いは先に決めておく（keyframeAnimator の中では、MainActor の格の比較を使えない）
        let pings = grade.isCaution
        let showsHalo = grade != .common
        let sparkleCount = grade.sparkleCount
        let sparklePalette = grade.hasRainbowSparkles ? HoloBand.colors.map { $0.mix(with: .black, by: 0.08) } : nil
        // 溜めの間に札の後ろから漏れる光。札が真横を向いた瞬間にまるごと見えるので、警告は控えめにし、ダークではさらに弱める
        let leak = RevealMotion.leakOpacity * (style == .alert ? 0.3 : 1) * (colorScheme == .dark ? 0.55 : 1)
        front
            // 返る瞬間に、表の縁が格の色で光り、虹の帯（警告は縞）が 1 回だけ面を横切る
            .overlay {
                Color.clear
                    .keyframeAnimator(initialValue: RevealMotion.idle, trigger: bursts) { _, progress in
                        RevealFaceShine(grade: grade, progress: progress, sweeps: !reduceMotion, direction: direction)
                    } keyframes: { _ in
                        RevealMotion.burstKeyframes(hold: hold)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .modifier(RevealFlipEffect(
                turn: turn,
                direction: direction,
                isFlat: reduceMotion,
                back: back.overlay { RevealBackRim(grade: grade, charge: charge) }
            ))
            // 返る向きと逆へ少し引く（めくる動きとは別の値にして、溜めとめくりを別々のばねで動かす）
            .rotation3DEffect(
                .degrees(-RevealMotion.windUpDegrees * windUp * direction * liftFactor),
                axis: (x: 0, y: 1, z: 0),
                perspective: RevealMotion.perspective
            )
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { card, angle in
                card.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                RevealMotion.shakeKeyframes
            }
            .keyframeAnimator(initialValue: 0.0, trigger: alerts) { card, shift in
                card.offset(x: shift)
            } keyframes: { _ in
                RevealMotion.alertKeyframes
            }
            .scaleEffect(1 + RevealMotion.chargeScale * charge * liftFactor)
            .offset(y: -RevealMotion.chargeHeight * charge * liftFactor)
            // 溜めの間、札の後ろから格の色の光が漏れてくる（パックから光が漏れる演出）
            .background {
                RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
                    .fill(grade.glow)
                    .padding(-8)
                    .blur(radius: 22)
                    .opacity(leak * charge)
                    .scaleEffect(1 + RevealMotion.chargeScale * charge * liftFactor)
                    .offset(y: -RevealMotion.chargeHeight * charge * liftFactor)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // 札の後ろから広がる後光（警告は、広がる輪）。ふつうの札には出さない
            .background {
                if !reduceMotion, showsHalo {
                    Color.clear
                        .keyframeAnimator(initialValue: RevealMotion.idle, trigger: bursts) { _, progress in
                            if pings {
                                CautionPing(grade: grade, progress: progress, overflow: RevealMotion.haloOverflow)
                            } else {
                                RevealHalo(grade: grade, progress: progress)
                            }
                        } keyframes: { _ in
                            RevealMotion.burstKeyframes(hold: hold)
                        }
                        .padding(-RevealMotion.haloOverflow)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if !reduceMotion, sparkleCount > 0 {
                    Color.clear
                        .keyframeAnimator(initialValue: RevealMotion.idle, trigger: bursts) { _, progress in
                            RevealSparkles(
                                grade: grade,
                                progress: progress,
                                overflow: RevealMotion.sparkleOverflow,
                                count: sparkleCount,
                                palette: sparklePalette
                            )
                        } keyframes: { _ in
                            RevealMotion.burstKeyframes(hold: hold)
                        }
                        .padding(-RevealMotion.sparkleOverflow)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .sensoryFeedback(trigger: pulse) { _, pulse in
                if pulse.isWarning {
                    return .warning
                }
                return pulse.isSharp
                    ? .impact(flexibility: .rigid, intensity: pulse.intensity)
                    : .impact(flexibility: .soft, intensity: pulse.intensity)
            }
            .onChange(of: isFaceUp) { _, faceUp in
                if faceUp {
                    turnUp()
                } else {
                    turnDown()
                }
            }
    }

    /// 溜めてから表に返す。めくりと後光の始まりはアニメーションの時計で遅らせ、溜めの長さがぶれないようにする
    /// （`Task.sleep` で待つと、負荷が高いときに裏のまま止まって見えた）
    private func turnUp() {
        let reveal = reveals + 1
        reveals = reveal
        bursts += 1
        let style = grade.chargeStyle
        if reduceMotion {
            withAnimation(RevealMotion.fade) {
                turn = 0
            }
            if style == .alert {
                pulse.playWarning()
            } else {
                pulse.play(intensity: grade.revealIntensity * 0.8, isSharp: false)
            }
            return
        }
        switch style {
        case .none:
            // ふつうの札: 溜めずにすぐ返し、軽く鳴らすだけ
            withAnimation(RevealMotion.flip) {
                turn = 0
            }
            pulse.play(intensity: grade.revealIntensity, isSharp: false)

        case .lift:
            shakes += 1
            withAnimation(RevealMotion.flip.delay(RevealMotion.chargeDuration)) {
                turn = 0
            }
            buildUp(step: 0, reveal: reveal)

        case .alert:
            alerts += 1
            withAnimation(RevealMotion.alertFlip.delay(RevealMotion.chargeDuration)) {
                turn = 0
            }
            buildUp(step: 0, reveal: reveal)
        }
    }

    /// 溜めを段ごとに強め、段の終わりで触覚を鳴らす（弱い 2 回の後、返る瞬間に強い 1 回か「警告」）。最後の段の後で溜めをほどく
    private func buildUp(step: Int, reveal: Int) {
        guard reveal == reveals else {
            return
        }
        let level = Double(step + 1) / Double(RevealMotion.chargeSteps)
        withAnimation(RevealMotion.chargeStep) {
            charge = level
            windUp = level
        } completion: {
            guard reveal == reveals else {
                return
            }
            if RevealMotion.chargeTicks.indices.contains(step) {
                pulse.play(intensity: RevealMotion.chargeTicks[step], isSharp: false)
                buildUp(step: step + 1, reveal: reveal)
            } else {
                if grade.chargeStyle == .alert {
                    pulse.playWarning()
                } else {
                    pulse.play(intensity: grade.revealIntensity, isSharp: true)
                }
                withAnimation(RevealMotion.release) {
                    charge = 0
                    windUp = 0
                }
            }
        }
    }

    /// 裏に戻す（取り消し・文を書くシートを閉じたとき）。行き過ぎず、触覚も鳴らさない
    private func turnDown() {
        reveals += 1
        withAnimation(reduceMotion ? RevealMotion.fade : RevealMotion.faceDown) {
            turn = 1
            charge = 0
            windUp = 0
        }
    }
}

/// 時間とばね。気持ちよさを優先して、録画を見ながら詰めた値
enum RevealMotion {
    /// 溜めの長さ。前の札が飛んでいく間（0.26 秒）に収める。3 段に分けて、段ごとに少しずつ強める
    static let chargeSteps = 3
    static let chargeStep = Animation.easeOut(duration: 0.05)
    static var chargeDuration: Double { 0.05 * Double(chargeSteps) }
    /// 溜めの段の終わりに鳴らす触覚の強さ（最後の段の後は、返る瞬間の強い 1 回）
    static let chargeTicks = [0.3, 0.5]
    /// 溜めで、返る向きと逆へ引く角度
    static let windUpDegrees = 8.0
    /// 溜めで持ち上げる量
    static let chargeScale: CGFloat = 0.05
    static let chargeHeight: CGFloat = 14
    /// 溜めで札の後ろから漏れる光の濃さ
    static let leakOpacity = 0.9
    /// 後光の筋の濃さ（画面いっぱいに広がるので、パステルの濃さに抑える）
    static let rayOpacity = 0.7
    /// 表に返る。速く回し、少し行き過ぎて止める（速すぎると回ったことが目に残らない）
    static let flip = Animation.spring(duration: 0.55, bounce: 0.24)
    /// 警告の札を返す。行き過ぎを小さくして、落ち着いて置く
    static let alertFlip = Animation.spring(duration: 0.55, bounce: 0.1)
    /// 裏に戻る（取り消し）。行き過ぎない
    static let faceDown = Animation.spring(duration: 0.4, bounce: 0.08)
    /// 溜めをほどく。持ち上げをゆっくり下ろす
    static let release = Animation.spring(duration: 0.55, bounce: 0.2)
    /// 視差効果を減らすときのフェード
    static let fade = Animation.easeInOut(duration: 0.2)
    /// 遠近感。1 が標準で、小さいほど手前の縁が大きくならない
    static let perspective: CGFloat = 0.45
    /// 真横を向いたとき（90°）に、どれだけ大きく・高くするか
    static let liftScale: CGFloat = 0.06
    static let liftHeight: CGFloat = 18
    /// 後光・粒を札の外へはみ出させる幅
    static let haloOverflow: CGFloat = 150
    static let sparkleOverflow: CGFloat = 90
    /// 後光・粒・面の光が一巡する時間
    static let burstDuration = 0.95
    /// 一巡の前後（0 と 1 では何も見えない）
    static let idle = 1.0

    /// 後光・粒・面の光の一巡。溜めの間（`hold`）は始めずに待つ
    static func burstKeyframes(hold: Double) -> some Keyframes<Double> {
        KeyframeTrack {
            MoveKeyframe(0)
            LinearKeyframe(0, duration: hold)
            LinearKeyframe(1, duration: burstDuration)
        }
    }

    /// 震え。弱く始めて強め、最後に止める（溜めの 0.15 秒に収める）
    static var shakeKeyframes: some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(0.8, duration: 0.025)
            LinearKeyframe(-1.2, duration: 0.025)
            LinearKeyframe(1.7, duration: 0.025)
            LinearKeyframe(-2.2, duration: 0.025)
            LinearKeyframe(1.8, duration: 0.025)
            LinearKeyframe(0, duration: 0.025)
        }
    }

    /// 警告の溜め。持ち上げずに、横に小さく 2 往復揺れる（「ちょっと待って」の揺れ。溜めの 0.15 秒に収める）
    static var alertKeyframes: some Keyframes<Double> {
        KeyframeTrack {
            LinearKeyframe(-3, duration: 0.025)
            LinearKeyframe(3.5, duration: 0.03)
            LinearKeyframe(-3, duration: 0.03)
            LinearKeyframe(2, duration: 0.03)
            LinearKeyframe(0, duration: 0.035)
        }
    }

    /// 表の縁の光。返り始めてすぐに強くなり、0.4 秒ほどで消える（`progress` は 0 から 1）
    static func flash(_ progress: Double) -> Double {
        let peak = 0.1
        if progress < peak {
            return progress / peak
        }
        return max(0, 1 - (progress - peak) / 0.35)
    }

    /// 警告の縁の脈。一巡の中で 2 回強まる
    static func alertPulse(_ progress: Double) -> Double {
        guard progress > 0, progress < 1 else {
            return 0
        }
        let beat = sin(min(progress / 0.62, 1) * 2 * .pi)
        let fade = max(0, 1 - progress / 0.75)
        return max(0, beat) * fade
    }

    /// 表を横切る帯の位置（0 で左の外、1 で右の外）。表が見えてから横切り、0.4 秒で抜ける
    static func sweep(_ progress: Double) -> Double {
        let start = 0.12
        let length = 0.42
        guard progress > start else {
            return 0
        }
        let value = min((progress - start) / length, 1)
        return 1 - pow(1 - value, 2)
    }

    /// 後光の強さ。すぐに広がり、少し保ってからゆっくり消える
    static func halo(_ progress: Double) -> Double {
        if progress < 0.1 {
            return progress / 0.1
        }
        if progress < 0.25 {
            return 1
        }
        let fall = (progress - 0.25) / 0.75
        return max(0, 1 - fall * fall * (3 - 2 * fall))
    }
}

/// 触覚の鳴らし分け。回数が変わるたびに、その強さで鳴らす
private struct RevealPulse: Equatable {
    var count = 0
    var intensity = 0.0
    var isSharp = false
    /// 慎重に決めてほしい札。返る瞬間に通知の「警告」の触覚を鳴らす
    var isWarning = false

    mutating func play(intensity: Double, isSharp: Bool) {
        count += 1
        self.intensity = intensity
        self.isSharp = isSharp
        isWarning = false
    }

    mutating func playWarning() {
        count += 1
        isWarning = true
    }
}

/// めくっている途中の見た目。`turn` を 1 コマごとに受け取り、90° を境に面を入れ替える
private struct RevealFlipEffect<Back: View>: ViewModifier, Animatable {
    var turn: Double
    let direction: Double
    /// 回さずにフェードで替える（視差効果を減らす）
    let isFlat: Bool
    let back: Back

    var animatableData: Double {
        get { turn }
        set { turn = newValue }
    }

    func body(content: Content) -> some View {
        let showsBack = turn > 0.5
        let fade = min(max(turn, 0), 1)
        // 真横を向いたときほど持ち上げる（溜めで 1 を超えたときと、ばねの行き過ぎでは下げない）
        let lift = isFlat ? 0 : max(0, sin(fade * .pi))
        ZStack {
            content
                .opacity(isFlat ? 1 - fade : (showsBack ? 0 : 1))
            back
                .rotation3DEffect(.degrees(isFlat ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlat ? fade : (showsBack ? 1 : 0))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // 正の角度では右の縁が手前に起きるので、向きの符号を逆にして「1 で右へ返る」にそろえる
        .rotation3DEffect(
            .degrees(isFlat ? 0 : -turn * 180 * direction),
            axis: (x: 0, y: 1, z: 0),
            perspective: RevealMotion.perspective
        )
        .scaleEffect(1 + RevealMotion.liftScale * lift)
        .offset(y: -RevealMotion.liftHeight * lift)
        .shadow(color: .black.opacity(0.14 * lift), radius: 26 * lift, y: 20 * lift)
    }
}
