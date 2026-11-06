import SwiftUI

// 札を表に返すときの光の部品（`RevealCard` が使う）。
// 裏の札の縁と印、表の面の光（虹の帯・警告の縞）、後光、警告の輪、きらめきの粒、慎重に決めてほしい札の警告の帯

/// 表に返った面の光。虹の帯（または警告の縞）が、めくった向きに 1 回だけ横切り、縁が格の色で光る。
/// 面全体は塗らない（文字が薄く見えて、押せない札のように見えるため）。
/// 虹は `HoloBand` を使い、ライトでは乗算・ダークではスクリーンで混ぜて、文字の濃さを変えない
struct RevealFaceShine: View {
    let grade: CardGrade
    /// 0 から 1 で一巡する
    let progress: Double
    /// 帯を横切らせるか（視差効果を減らすときは縁の光だけ）
    let sweeps: Bool
    /// めくった向き（1 で左から右へ横切る）
    let direction: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
        let sweep = RevealMotion.sweep(progress)
        let position = (sweep * 2.2 - 1.1) * direction
        let edge = grade.isCaution ? RevealMotion.alertPulse(progress) : RevealMotion.flash(progress)
        ZStack {
            if grade != .common {
                shape
                    .strokeBorder(grade.tone.mix(with: grade.glow, by: 0.3), lineWidth: grade.isCaution ? 10 : 14)
                    .blur(radius: grade.isCaution ? 6 : 10)
                    .opacity(edge)
            }
            if sweeps, sweep > 0, sweep < 1 {
                Group {
                    if grade.isCaution {
                        HazardBand(position: position, tint: grade.tone)
                            .opacity(colorScheme == .dark ? 0.38 : 0.5)
                    } else {
                        HoloBand(position: position)
                            .opacity(grade.rainbowStrength)
                    }
                }
                .compositingGroup()
                .blendMode(colorScheme == .dark ? .screen : .multiply)
            }
        }
        .clipShape(shape)
    }
}

/// 裏の札の縁の光と印。待っている間は格の色でうっすら光り、溜めで強まる
struct RevealBackRim: View {
    let grade: CardGrade
    let charge: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
        let strength = min(1, grade.restingRim + charge)
        ZStack(alignment: .bottom) {
            shape
                .strokeBorder(grade.tone.opacity(strength), lineWidth: 2 + 2 * charge)
                .shadow(color: grade.glow.opacity(strength), radius: 6 + 12 * charge)
                .shadow(color: grade.glow.opacity(0.6 * strength), radius: 2)
            if let badge = grade.badge {
                Label(badge.title, systemImage: badge.systemImage)
                    .appFont(.caption, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(grade.tone.mix(with: .black, by: 0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    .padding(.bottom, 34)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 札の後ろから広がる後光。格の色のにじむ光と、回りながら伸びる光の筋
struct RevealHalo: View {
    let grade: CardGrade
    /// 0 から 1 で一巡する
    let progress: Double

    var body: some View {
        let strength = RevealMotion.halo(progress)
        Canvas { context, size in
            guard strength > 0 else {
                return
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let reach = min(size.width, size.height) / 2
            let grow = 1 - pow(1 - min(progress * 2.5, 1), 3)
            // 札の後ろでにじむ光
            let glowRadius = reach * (0.55 + 0.45 * grow)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - glowRadius,
                    y: center.y - glowRadius * 1.25,
                    width: glowRadius * 2,
                    height: glowRadius * 2.5
                )),
                with: .radialGradient(
                    Gradient(colors: [grade.glow.opacity(0.85 * strength), grade.glow.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: glowRadius * 1.2
                )
            )
            guard grade.rayCount > 0 else {
                return
            }
            // 光の筋。根元が細く、先へ行くほど薄くなる三角形を、ゆっくり回しながら伸ばす
            let length = hypot(size.width, size.height) / 2 * (0.5 + 0.5 * grow)
            let spin = Angle.degrees(progress * 28).radians
            let width = .pi / Double(grade.rayCount) * 0.42
            var rays = Path()
            for index in 0..<grade.rayCount {
                let angle = spin + Double(index) / Double(grade.rayCount) * 2 * .pi
                rays.move(to: center)
                rays.addLine(to: CGPoint(x: center.x + cos(angle - width) * length, y: center.y + sin(angle - width) * length))
                rays.addLine(to: CGPoint(x: center.x + cos(angle + width) * length, y: center.y + sin(angle + width) * length))
                rays.closeSubpath()
            }
            context.fill(
                rays,
                with: .radialGradient(
                    Gradient(colors: [
                        grade.glow.opacity(RevealMotion.rayOpacity * strength),
                        grade.glow.mix(with: grade.tone, by: 0.5).opacity(0.5 * RevealMotion.rayOpacity * strength),
                        grade.tone.opacity(0)
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: length
                )
            )
        }
    }
}

/// 警告の札の後ろから、縁の形の輪が 2 つ広がって消える（注意を引く「ピン」。祝う後光や粒は出さない）
struct CautionPing: View {
    let grade: CardGrade
    /// 0 から 1 で一巡する
    let progress: Double
    /// 札の外にはみ出させた幅（この内側が札）
    let overflow: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 札が真横を向いた瞬間に後ろの光がまるごと見えるので、ぼかして薄くする（ダークでは赤が強く見えるので一段控える）
        let glowScale = colorScheme == .dark ? 0.18 : 0.3
        Canvas { context, size in
            guard progress > 0, progress < 1 else {
                return
            }
            let card = CGRect(x: overflow, y: overflow, width: size.width - overflow * 2, height: size.height - overflow * 2)
            for ring in 0..<2 {
                let start = Double(ring) * 0.22
                let local = (progress - start) / 0.55
                guard local > 0, local < 1 else {
                    continue
                }
                let grow = 1 - pow(1 - local, 2)
                let spread = 8 + 46 * grow
                let rect = card.insetBy(dx: -spread, dy: -spread)
                let path = Path(roundedRect: rect, cornerRadius: SwipeCard<EmptyView>.cornerRadius + spread, style: .continuous)
                let opacity = (1 - local) * 0.75
                var glow = context
                glow.addFilter(.blur(radius: 6))
                glow.stroke(path, with: .color(grade.glow.opacity(opacity)), lineWidth: 8)
                context.stroke(path, with: .color(grade.tone.opacity(opacity * 0.8)), lineWidth: 2)
            }
            // 札の後ろでにじむ淡い赤
            var haze = context
            haze.addFilter(.blur(radius: 18))
            haze.fill(
                Path(roundedRect: card.insetBy(dx: -10, dy: -10), cornerRadius: SwipeCard<EmptyView>.cornerRadius + 10),
                with: .color(grade.glow.opacity(RevealMotion.halo(progress) * glowScale))
            )
        }
        .blur(radius: 1)
    }
}

/// 返る瞬間に札の縁からはじけるきらめきの粒。並びと大きさは番号から決め、毎回同じに出す（ランダムにしない）
struct RevealSparkles: View {
    let grade: CardGrade
    /// 0 から 1 で一巡する
    let progress: Double
    /// 札の外にはみ出させた幅（この内側が札）
    let overflow: CGFloat
    /// 粒の数
    let count: Int
    /// 粒の色を番号ごとに替える（nil なら格の色）
    let palette: [Color]?

    var body: some View {
        let sparkleCount = count
        Canvas { context, size in
            guard progress > 0, progress < 1, sparkleCount > 0 else {
                return
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let card = CGSize(width: size.width - overflow * 2, height: size.height - overflow * 2)
            // 速く飛び出して減速し、0.6 秒ほどで消える
            let travel = 1 - pow(1 - min(progress / 0.55, 1), 3)
            let fade = progress < 0.05 ? progress / 0.05 : max(0, 1 - (progress - 0.2) / 0.4)
            for index in 0..<sparkleCount {
                let seed = Double(index)
                let angle = (seed + 0.5 * Self.noise(seed, 1)) / Double(sparkleCount) * 2 * .pi - .pi / 2
                let tone = palette.map { $0[index % $0.count] } ?? grade.tone
                // 札の縁のあたりから出て、外へ飛ぶ
                let start = CGPoint(
                    x: center.x + cos(angle) * card.width * 0.48,
                    y: center.y + sin(angle) * card.height * 0.48
                )
                let distance = (30 + 60 * Self.noise(seed, 2)) * travel
                let point = CGPoint(x: start.x + cos(angle) * distance, y: start.y + sin(angle) * distance)
                let radius = (8 + 7 * Self.noise(seed, 3)) * (1 - 0.4 * progress)
                let star = Self.star(at: point, radius: radius, turn: progress * 1.5 + Self.noise(seed, 4))
                // 色の星に白い芯。にじみを重ねて光って見せる
                var glow = context
                glow.addFilter(.blur(radius: radius * 0.35))
                glow.fill(star, with: .color(tone.opacity(0.8 * fade)))
                context.fill(star, with: .color(tone.opacity(fade)))
                let core = radius * 0.28
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
                    with: .color(.white.opacity(fade))
                )
            }
        }
    }

    /// 番号ごとに決まった 0 から 1 の値
    private static func noise(_ seed: Double, _ salt: Double) -> Double {
        let value = sin(seed * 12.9898 + salt * 78.233) * 43_758.5453
        return value - value.rounded(.down)
    }

    /// 4 つの角の星（きらめき）
    private static func star(at center: CGPoint, radius: CGFloat, turn: Double) -> Path {
        var path = Path()
        for step in 0..<8 {
            let angle = turn + Double(step) * .pi / 4
            let length = step.isMultiple(of: 2) ? radius : radius * 0.32
            let point = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
/// 斜めの虹の帯。パステルの 5 色を並べ、両端を透明にぼかす。
///
/// 札の枠いっぱいの 1 枚のグラデーションで描き、軸の両端（`startPoint` / `endPoint`）を動かして帯を走らせる
/// （回した大きな帯を置くと、札のアクセシビリティの枠が画面の外まで広がり、VoiceOver の枠と UI テストの押す位置がずれるため）
struct HoloBand: View {
    /// -1〜1。札の真ん中が 0。-1 と 1 では帯が札の外に出る
    let position: Double

    static let colors = [Theme.Pastel.rose, Theme.Pastel.butter, Theme.Pastel.mint, Theme.Pastel.sky, Theme.Pastel.lavender]

    /// 帯の幅（札の幅に対する軸の長さ）と、傾き（縦の軸に対して右へ倒す量）
    private static let span = 0.42
    private static let slant = 0.14

    var body: some View {
        let center = 0.5 + position * (0.5 + Self.span)
        LinearGradient(
            stops: Self.stops,
            startPoint: UnitPoint(x: center - Self.span / 2, y: 0.5 - Self.slant),
            endPoint: UnitPoint(x: center + Self.span / 2, y: 0.5 + Self.slant)
        )
    }

    private static var stops: [Gradient.Stop] {
        let inner = colors.enumerated().map { index, color in
            Gradient.Stop(color: color, location: 0.2 + 0.6 * Double(index) / Double(colors.count - 1))
        }
        let start = Gradient.Stop(color: colors[0].opacity(0), location: 0)
        let end = Gradient.Stop(color: colors[colors.count - 1].opacity(0), location: 1)
        return [start] + inner + [end]
    }
}

/// 斜めの縞の帯（警告のテープ）。帯の幅は札の幅の 4 割で、縞は格の色と透明の繰り返し
struct HazardBand: View {
    /// -1〜1。札の真ん中が 0。-1 と 1 では帯が札の外に出る
    let position: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = size.width * 0.42
            Canvas { context, canvas in
                let stripe: CGFloat = 14
                var path = Path()
                var x = -canvas.height
                while x < canvas.width + canvas.height {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + stripe, y: 0))
                    path.addLine(to: CGPoint(x: x + stripe + canvas.height * 0.6, y: canvas.height))
                    path.addLine(to: CGPoint(x: x + canvas.height * 0.6, y: canvas.height))
                    path.closeSubpath()
                    x += stripe * 2
                }
                context.fill(path, with: .color(tint))
            }
            .frame(width: width, height: size.height)
            // 帯の両端をぼかして、縞の帯が光のように通り過ぎて見えるようにする
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.3),
                        .init(color: .black, location: 0.7),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .offset(x: (size.width - width) / 2 + position * (size.width + width) / 2)
        }
    }
}

/// 慎重に決めてほしい札の表の一番上に出す、警告の帯。札と一緒に動き、読み上げでも理由が分かるようにする
struct CautionStrip: View {
    let caution: Caution

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let grade = CardGrade.caution(caution)
        Label("\(caution.label)に関わる判断です。慎重に選んでください", systemImage: caution.systemImage)
            .labelStyle(.titleAndIcon)
            .appFont(.caption, weight: .bold)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(colorScheme == .dark ? grade.glow : grade.tone.mix(with: .black, by: 0.35))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    grade.glow.opacity(colorScheme == .dark ? 0.22 : 0.55)
                    // 警告のテープのような斜めの縞を、文字の邪魔にならない濃さで敷く
                    HazardBand(position: 0, tint: grade.tone)
                        .scaleEffect(x: 2.4, anchor: .center)
                        .opacity(0.12)
                }
            }
            .overlay(alignment: .bottom) {
                grade.tone.opacity(0.5).frame(height: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("注意: \(caution.label)に関わる判断です")
    }
}
