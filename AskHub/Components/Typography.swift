import CoreText
import SwiftUI

/// アプリの文字。英数字は丸い書体の Nunito、かなと漢字はシステムの書体（ヒラギノ角ゴ）で出す
/// （ユーザーが 7 つの書体を実機で見比べて決めた。2026-11-03）。
///
/// Nunito はかなと漢字を持たないので、その文字は CoreText がシステムの書体で補う（太さも合わせてくれる）。
/// フォントは可変フォント 1 ファイル（`AskHub/Fonts/Nunito[wght].ttf`。Google Fonts の `google/fonts` の `ofl/nunito`、
/// SIL Open Font License 1.1。ライセンスは同じフォルダの `Nunito-OFL.txt`）。大きさと太さは text style のまま
enum AppFont {
    /// 太さ（100〜900）ごとの名前付きインスタンスの PostScript 名
    private static let faces: [Int: String] = [
        200: "Nunito-ExtraLight", 300: "Nunito-Light", 400: "Nunito-Regular", 500: "Nunito-Medium",
        600: "Nunito-SemiBold", 700: "Nunito-Bold", 800: "Nunito-ExtraBold", 900: "Nunito-Black"
    ]

    /// 起動のときにフォントを登録し、UIKit が描くナビゲーションバーの見出しとタブの名前にも使う
    static func register() {
        if let url = Bundle.main.url(forResource: "Nunito[wght]", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        #if os(iOS)
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = uiFont(.largeTitle, weight: .bold).map { [.font: $0] }
        navigationBar.titleTextAttributes = uiFont(.headline, weight: .semibold).map { [.font: $0] }
        let tabItem = UITabBarItem.appearance()
        let attributes = uiFont(.caption2, weight: .semibold).map { [NSAttributedString.Key.font: $0] }
        tabItem.setTitleTextAttributes(attributes, for: .normal)
        tabItem.setTitleTextAttributes(attributes, for: .selected)
        #endif
    }

    /// text style と太さに合う文字。Dynamic Type の設定に合わせて伸び縮みする
    static func font(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        .custom(faceName(for: weight ?? style.defaultWeight), size: style.baseSize, relativeTo: style)
    }

    /// いちばん近い太さの PostScript 名。同じだけ離れていたら太いほうにする
    static func faceName(for weight: Font.Weight) -> String {
        let target = weight.value
        return faces.min { lhs, rhs in
            let left = abs(lhs.key - target)
            let right = abs(rhs.key - target)
            return left == right ? lhs.key > rhs.key : left < right
        }?.value ?? "Nunito-Regular"
    }

    #if os(iOS)
    private static func uiFont(_ style: Font.TextStyle, weight: Font.Weight) -> UIFont? {
        UIFont(name: faceName(for: weight), size: style.baseSize).map {
            UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(for: $0)
        }
    }
    #endif
}

extension View {
    /// 文字の大きさ（text style）と太さを決める。書体はアプリの書体（AppFont）
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        font(AppFont.font(style, weight: weight))
    }
}

private extension Font.TextStyle {
    /// Dynamic Type が「標準」のときの大きさ（pt）。`relativeTo:` で利用者の設定に合わせて伸び縮みする
    var baseSize: CGFloat {
        Self.baseSizes[self] ?? Self.baseSizes[.body] ?? 17
    }

    /// 太さを決めていないときの太さ（見出しはシステムと同じく少し太い）
    var defaultWeight: Font.Weight {
        guard self == .headline else {
            return .regular
        }
        #if os(macOS)
        return .bold
        #else
        return .semibold
        #endif
    }

    #if os(macOS)
    static let baseSizes: [Self: CGFloat] = [
        .largeTitle: 26, .title: 22, .title2: 17, .title3: 15, .headline: 13, .body: 13,
        .callout: 12, .subheadline: 11, .footnote: 10, .caption: 10, .caption2: 10
    ]
    #else
    static let baseSizes: [Self: CGFloat] = [
        .largeTitle: 34, .title: 28, .title2: 22, .title3: 20, .headline: 17, .body: 17,
        .callout: 16, .subheadline: 15, .footnote: 13, .caption: 12, .caption2: 11
    ]
    #endif

    #if os(iOS)
    var uiTextStyle: UIFont.TextStyle {
        Self.uiTextStyles[self] ?? .body
    }

    static let uiTextStyles: [Self: UIFont.TextStyle] = [
        .largeTitle: .largeTitle, .title: .title1, .title2: .title2, .title3: .title3, .headline: .headline, .body: .body,
        .callout: .callout, .subheadline: .subheadline, .footnote: .footnote, .caption: .caption1, .caption2: .caption2
    ]
    #endif
}

private extension Font.Weight {
    /// 太さの数値（100〜900）
    var value: Int {
        Self.values[self] ?? 400
    }

    static let values: [Self: Int] = [
        .ultraLight: 100, .thin: 200, .light: 300, .regular: 400, .medium: 500,
        .semibold: 600, .bold: 700, .heavy: 800, .black: 900
    ]
}
