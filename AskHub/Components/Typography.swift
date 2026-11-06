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

    /// 行間（文字の大きさの倍率）。Nunito の行間（約 1.36 倍）はシステムの書体より広く、一覧の行が高くなるので少し詰める
    /// （ユーザーの要望。2026-11-03）。1 より小さくすると文字の上が切れるので、1.2 より下げない
    static let lineHeight = AttributedString.LineHeight.multiple(factor: 1.25)

    /// 起動のときにフォントを登録し、UIKit が描くナビゲーションバーの見出しとタブの名前にも使う
    static func register() {
        if let url = Bundle.main.url(forResource: "Nunito[wght]", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        applyToSystemBars()
    }

    /// ナビゲーションバーの見出しは、いまのテキストサイズの大きさにする（小さくしたら見出しも縮む）。
    /// タブの名前は操作の部品なので、テキストサイズによらず標準の大きさのままにする。テキストサイズが変わったら呼び直す
    static func applyToSystemBars() {
        #if os(iOS)
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = uiFont(.largeTitle, weight: .bold).map { [.font: $0] }
        navigationBar.titleTextAttributes = uiFont(.headline, weight: .semibold).map { [.font: $0] }
        let tabItem = UITabBarItem.appearance()
        let tabFont = UIFont(name: faceName(for: .semibold), size: Font.TextStyle.caption2.baseSize)
        let attributes = tabFont.map { [NSAttributedString.Key.font: $0] }
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
    /// いまのテキストサイズでの大きさ（`UIFontMetrics` は標準より小さい設定で縮めないので、システムの書体の大きさを使う）
    private static func uiFont(_ style: Font.TextStyle, weight: Font.Weight) -> UIFont? {
        UIFont(name: faceName(for: weight), size: UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize)
    }
    #endif
}

extension View {
    /// 文字の大きさ（text style）と太さを決める。書体はアプリの書体（AppFont）
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        font(AppFont.font(style, weight: weight))
    }

    /// 操作の部品（ボタン・操作の帯・入力欄）は、テキストサイズを小さくしても標準より小さくしない。
    /// 押しやすさ（HIG の 44pt の当たり）を保ったまま、中身だけを小さくして一画面に多く見せる（ユーザーの要望。2026-11-03）
    func keepsControlSize() -> some View {
        dynamicTypeSize(.large...)
    }
}

/// 中身の寸法（アプリのアイコン・印）を、文字の大きさの設定に合わせて伸び縮みさせる倍率（本文の大きさの、標準との比）。
/// 文字だけが縮んでアイコンが固定だと、テキストサイズを小さくしても行の高さが変わらないため（ユーザーの要望。2026-11-03）。
/// `@ScaledMetric` は標準より小さい設定では 1 のままで縮まないので、テキストサイズの段階から求める。
/// 大きくする側は 1.6 倍で止める（アクセシビリティの大きさで、アイコンが一覧を埋めないように）。`@ContentScale private var scale` で使う
@propertyWrapper
struct ContentScale: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var size

    var wrappedValue: CGFloat {
        min((Self.bodySizes[size] ?? 17) / 17, 1.6)
    }

    /// テキストサイズの段階ごとの本文（body）の大きさ（pt）。iOS の Dynamic Type の表と同じ
    private static let bodySizes: [DynamicTypeSize: CGFloat] = [
        .xSmall: 14, .small: 15, .medium: 16, .large: 17, .xLarge: 19, .xxLarge: 21, .xxxLarge: 23,
        .accessibility1: 28, .accessibility2: 33, .accessibility3: 40, .accessibility4: 47, .accessibility5: 53
    ]
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
