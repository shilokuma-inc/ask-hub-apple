import SwiftUI

/// 対象のアプリのアイコン。どのアプリの判断かを一目で分かるように、一覧・カード・epic の見出しに出す
struct AppIconView: View {
    let repository: TargetRepository?
    /// テキストサイズが標準のときの大きさ。設定に合わせて伸び縮みする（ContentScale）
    var size: CGFloat = 40

    @ContentScale private var scale
    private var side: CGFloat { size * scale }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
        content
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch repository?.icon ?? .monogram {
        case .image(let url):
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                monogram
            }

        case let .symbol(name, tint):
            ZStack {
                // 上を少し明るくしたパステルのグラデーション
                LinearGradient(colors: [tint.color.mix(with: .white, by: 0.2), tint.color], startPoint: .top, endPoint: .bottom)
                Image(systemName: name)
                    .font(.system(size: side * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }

        case .monogram:
            monogram
        }
    }

    private var monogram: some View {
        ZStack {
            Color.secondary.opacity(0.25)
            Text(String(repository?.appName.prefix(1) ?? "?"))
                .font(.system(size: side * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

extension IconTint {
    /// パステルの濃いめの色（白い記号が読める濃さ）
    var color: Color {
        switch self {
        case .green: Theme.Tone.mint
        case .orange: Theme.Tone.peach
        case .blue: Theme.Tone.sky
        case .purple: Theme.Tone.lavender
        case .pink: Theme.Tone.rose
        case .teal: Theme.Tone.aqua
        case .indigo: Theme.Tone.lavender
        case .gray: Theme.Tone.slate
        }
    }
}

/// アプリのアイコンと名前の見出し（カードや epic の画面の上に出す）
struct AppHeaderView: View {
    let repository: TargetRepository?
    let subtitle: String
    var iconSize: CGFloat = 32

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(repository: repository, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository?.appName ?? "不明なリポジトリ")
                    .appFont(.subheadline, weight: .semibold)
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("アプリのアイコン") {
    HStack {
        ForEach(DemoData.repositories + DemoData.candidates.prefix(1)) { repository in
            AppIconView(repository: repository)
        }
    }
    .padding()
}
