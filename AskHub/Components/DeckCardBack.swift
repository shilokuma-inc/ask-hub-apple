import SwiftUI

/// 札の裏。後ろに重ねたカードは裏向きにし、どのアプリの札かを色とアイコンだけで見せる。
///
/// アプリの色のパステルの地に、ひし形の格子と二重の枠を描き、真ん中にアプリのアイコンを置く（トランプの裏のような札）
struct DeckCardBack: View {
    let repository: TargetRepository?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
        ZStack {
            LinearGradient(colors: ground, startPoint: .topLeading, endPoint: .bottomTrailing)
            CardBackLattice()
                .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.16 : 0.34))
            // 真ん中を明るくして、アイコンを浮かせる
            RadialGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.18 : 0.5), .white.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: 190
            )
            // 札の裏らしい二重の枠
            shape.inset(by: 12).strokeBorder(.white.opacity(0.85), lineWidth: 2)
            shape.inset(by: 18).strokeBorder(.white.opacity(0.45), lineWidth: 1)
            ornaments
                .padding(30)
            medallion
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
        .accessibilityHidden(true)
    }

    /// 真ん中の丸い台とアプリのアイコン
    private var medallion: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(colorScheme == .dark ? 0.22 : 0.9))
                .frame(width: 124, height: 124)
            Circle()
                .strokeBorder(tint.opacity(0.7), lineWidth: 2.5)
                .frame(width: 124, height: 124)
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .frame(width: 140, height: 140)
            AppIconView(repository: repository, size: 68)
                .shadow(color: tint.mix(with: .black, by: 0.3).opacity(0.3), radius: 6, y: 3)
        }
    }

    /// 四隅の小さなきらめき
    private var ornaments: some View {
        let sparkle = Image(systemName: "sparkle")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
        return VStack {
            HStack {
                sparkle
                Spacer()
                sparkle
            }
            Spacer()
            HStack {
                sparkle
                Spacer()
                sparkle
            }
        }
    }

    /// 地の色。ライトではアプリの色を白に寄せ、ダークでは黒に沈める
    private var ground: [Color] {
        if colorScheme == .dark {
            return [tint.mix(with: .black, by: 0.35), tint.mix(with: .black, by: 0.55)]
        }
        return [tint.mix(with: .white, by: 0.5), tint.mix(with: .white, by: 0.18)]
    }

    private var tint: Color {
        if case let .symbol(_, tint) = repository?.icon {
            return tint.color
        }
        return Theme.Tone.lavender
    }
}

/// ひし形の格子と、ひし形の真ん中の点
private struct CardBackLattice: View {
    var spacing: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            // 線の起点を間隔の倍数にそろえ、x = 0 の上端に線の交わる点が来るようにする
            let reach = ((size.width + size.height) / spacing).rounded(.up) * spacing
            var lines = Path()
            var dots = Path()
            for step in stride(from: -reach, through: reach, by: spacing) {
                // 右下がりと左下がりの線を同じ間隔で引くと、ひし形の格子になる
                lines.move(to: CGPoint(x: step, y: 0))
                lines.addLine(to: CGPoint(x: step + size.height, y: size.height))
                lines.move(to: CGPoint(x: step, y: 0))
                lines.addLine(to: CGPoint(x: step - size.height, y: size.height))
            }
            // ひし形の真ん中は、半目ごとの段で、交わる点と横に半目ずれたところ
            let half = spacing / 2
            for row in 0...Int(size.height / half) {
                let shift = row.isMultiple(of: 2) ? half : 0
                let y = CGFloat(row) * half
                for x in stride(from: shift, through: size.width, by: spacing) {
                    dots.addEllipse(in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                }
            }
            context.stroke(lines, with: .foreground, lineWidth: 1)
            context.fill(dots, with: .foreground)
        }
    }
}

#Preview("札の裏") {
    HStack(spacing: 16) {
        ForEach(DemoData.repositories.prefix(2)) { repository in
            DeckCardBack(repository: repository)
                .frame(width: 220, height: 340)
        }
    }
    .padding()
}
