import SwiftUI

/// アプリ全体の色。パステルを基調にしておしゃれに見せる（ユーザーの要望。2026-11-03）。
///
/// 背景や塗りにはパステルを使い、文字・ボタン・印には同じ系統の少し濃い色を使う（パステルのままでは読みにくいため）。
/// ダークモードでは、塗りを暗く沈め、文字の色を明るくする
enum Theme {
    /// 主な色（ボタン・リンク・選んでいるもの）。ラベンダー
    static let accent = Color(light: .rgb(0.42, 0.38, 0.82), dark: .rgb(0.74, 0.70, 1.0))
    static let success = Color(light: .rgb(0.15, 0.56, 0.43), dark: .rgb(0.56, 0.88, 0.73))
    static let warning = Color(light: .rgb(0.82, 0.47, 0.17), dark: .rgb(1.0, 0.77, 0.53))
    static let danger = Color(light: .rgb(0.80, 0.27, 0.38), dark: .rgb(1.0, 0.64, 0.70))
    static let info = Color(light: .rgb(0.25, 0.49, 0.83), dark: .rgb(0.64, 0.79, 1.0))

    /// 塗りに使うパステル
    enum Pastel {
        static let lavender = Color.rgb(0.71, 0.65, 0.98)
        static let mint = Color.rgb(0.55, 0.86, 0.74)
        static let peach = Color.rgb(1.0, 0.74, 0.62)
        static let sky = Color.rgb(0.58, 0.78, 1.0)
        static let rose = Color.rgb(1.0, 0.64, 0.72)
        static let butter = Color.rgb(1.0, 0.86, 0.56)
    }

    /// 印やアイコンの塗りに使う、少し濃いパステル（白い記号が読める濃さ）
    enum Tone {
        static let lavender = Color.rgb(0.58, 0.52, 0.93)
        static let mint = Color.rgb(0.33, 0.74, 0.60)
        static let peach = Color.rgb(0.98, 0.60, 0.44)
        static let sky = Color.rgb(0.43, 0.65, 0.96)
        static let rose = Color.rgb(0.94, 0.48, 0.60)
        static let butter = Color.rgb(0.94, 0.72, 0.32)
        static let aqua = Color.rgb(0.34, 0.74, 0.80)
        static let slate = Color.rgb(0.58, 0.61, 0.70)
    }
}

/// 画面の後ろの背景。淡いピーチ・ラベンダー・ミント・空色を重ねたグラデーション
struct PastelBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(
                colors: [Theme.Pastel.peach.opacity(0.30), Theme.Pastel.lavender.opacity(0.26), Theme.Pastel.mint.opacity(0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [Theme.Pastel.sky.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Theme.Pastel.rose.opacity(0.16), .clear], center: .bottomLeading, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// 一覧やフォームの背景をパステルのグラデーションにする（行は白い札のように浮かせる）
    func pastelBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { PastelBackground() }
    }
}

extension Color {
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }

    /// ライトとダークで色を変える
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #endif
    }
}
