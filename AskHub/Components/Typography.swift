import CoreText
import SwiftUI

/// アプリの書体。文字の大きさと太さは text style のまま、書体だけを差し替える。
///
/// いまはシステムの書体で出す。見え方を比べるため、デバッグのビルドでは同梱したフォントに切り替えられる
/// （ユーザーの要望。2026-11-03）。フォントは git に入れず、`AskHub/DebugFonts/` に置いたものだけがビルドに入る。
/// 置くのは Google Fonts の `google/fonts` の `ofl/<フォルダ>` の ttf と OFL.txt（すべて SIL Open Font License 1.1）。
/// 静的なフォントのファイル名は PostScript 名と同じ（例: `ZenMaruGothic-Bold.ttf`）
enum AppTypeface: String, CaseIterable, Identifiable {
    case system
    /// ofl/zenmarugothic
    case zenMaruGothic
    /// ofl/mplusrounded1c
    case mPlusRounded
    /// ofl/zenkakugothicnew
    case zenKakuGothic
    /// ofl/murecho（可変フォント `Murecho[wght].ttf` の 1 ファイル）
    case murecho
    /// ofl/bizudpgothic
    case bizUDPGothic
    /// ofl/nunito（可変フォント `Nunito[wght].ttf` の 1 ファイル。かなと漢字は持たない）
    case nunito

    static let preferenceKey = "debugTypeface"

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "システム（ヒラギノ角ゴ・SF）"
        case .zenMaruGothic: "Zen Maru Gothic"
        case .mPlusRounded: "M PLUS Rounded 1c"
        case .zenKakuGothic: "Zen Kaku Gothic New"
        case .murecho: "Murecho"
        case .bizUDPGothic: "BIZ UDPゴシック"
        case .nunito: "Nunito ＋ システム"
        }
    }

    var summary: String {
        switch self {
        case .system: "いまの書体"
        case .zenMaruGothic: "上品でやわらかい丸ゴシック"
        case .mPlusRounded: "ころんとした親しみやすい丸ゴシック"
        case .zenKakuGothic: "端正ですっきりした角ゴシック"
        case .murecho: "細身でモダンなゴシック"
        case .bizUDPGothic: "読みやすさを重視したゴシック"
        case .nunito: "英数字だけ丸く、かなと漢字はシステム"
        }
    }

    /// 太さ（100〜900）ごとの PostScript 名。無い太さは近いものを使う
    private var faces: [Int: String] {
        switch self {
        case .system:
            [:]

        case .zenMaruGothic:
            [400: "ZenMaruGothic-Regular", 500: "ZenMaruGothic-Medium", 700: "ZenMaruGothic-Bold", 900: "ZenMaruGothic-Black"]

        case .mPlusRounded:
            [400: "RoundedMplus1c-Regular", 500: "RoundedMplus1c-Medium", 700: "RoundedMplus1c-Bold", 800: "RoundedMplus1c-ExtraBold"]

        case .zenKakuGothic:
            [400: "ZenKakuGothicNew-Regular", 500: "ZenKakuGothicNew-Medium", 700: "ZenKakuGothicNew-Bold", 900: "ZenKakuGothicNew-Black"]

        case .murecho:
            [400: "Murecho-Regular", 500: "Murecho-Medium", 600: "Murecho-SemiBold", 700: "Murecho-Bold", 800: "Murecho-ExtraBold"]

        case .bizUDPGothic:
            [400: "BIZUDPGothic-Regular", 700: "BIZUDPGothic-Bold"]

        case .nunito:
            [400: "Nunito-Regular", 500: "Nunito-Medium", 600: "Nunito-SemiBold", 700: "Nunito-Bold", 800: "Nunito-ExtraBold"]
        }
    }

    /// フォントがビルドに入っていて使えるか（システムはいつも使える）
    var isAvailable: Bool {
        faces.values.allSatisfy { name in
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            return CTFontCopyPostScriptName(font) as String == name
        }
    }

    /// text style と太さに合う文字。Dynamic Type の設定に合わせて伸び縮みする
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let weight = weight ?? style.defaultWeight
        guard let name = faceName(for: weight) else {
            return .system(style, weight: weight)
        }
        return .custom(name, size: style.baseSize, relativeTo: style)
    }

    /// いちばん近い太さの PostScript 名。同じだけ離れていたら太いほうにする
    func faceName(for weight: Font.Weight) -> String? {
        let target = weight.value
        return faces.min { lhs, rhs in
            let left = abs(lhs.key - target)
            let right = abs(rhs.key - target)
            return left == right ? lhs.key > rhs.key : left < right
        }?.value
    }
}

extension EnvironmentValues {
    /// 画面で使う書体。ふだんはシステム。デバッグのビルドでは設定で選べる
    @Entry var appTypeface: AppTypeface = .system
}

extension View {
    /// 文字の大きさ（text style）と太さを決める。書体は環境の `appTypeface` に従う
    func appFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(AppFontModifier(style: style, weight: weight))
    }

    /// デバッグのビルドでは、設定で選んだ書体を画面全体に使う
    func typefaceFromSettings() -> some View {
        modifier(TypefaceSettingModifier())
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appTypeface) private var typeface
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(typeface.font(style, weight: weight))
    }
}

private struct TypefaceSettingModifier: ViewModifier {
    @AppStorage(AppTypeface.preferenceKey) private var typeface: AppTypeface = .system

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .environment(\.appTypeface, typeface)
            .font(typeface.font(.body))
            .onChange(of: typeface) { typeface.applyToSystemBars() }
        #else
        content
        #endif
    }
}

#if DEBUG
extension AppTypeface {
    /// 起動のときに、同梱したフォントを登録し、選んである書体をナビゲーションバーとタブバーに使う
    static func prepareForDebug() {
        let urls = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let stored = UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
        stored.applyToSystemBars()
    }

    /// ナビゲーションバーの見出しとタブの名前は UIKit が描くので、appearance で書体を変える。
    /// 変えた後に作られたバーから効く（画面の作り直しは RootView が書体ごとに行う）
    func applyToSystemBars() {
        #if os(iOS)
        let navigationBar = UINavigationBar.appearance()
        navigationBar.largeTitleTextAttributes = uiFont(.largeTitle, weight: .bold).map { [.font: $0] }
        navigationBar.titleTextAttributes = uiFont(.headline, weight: .semibold).map { [.font: $0] }
        let tabItem = UITabBarItem.appearance()
        let attributes = uiFont(.caption2, weight: .medium).map { [NSAttributedString.Key.font: $0] }
        tabItem.setTitleTextAttributes(attributes, for: .normal)
        tabItem.setTitleTextAttributes(attributes, for: .selected)
        #endif
    }

    #if os(iOS)
    private func uiFont(_ style: Font.TextStyle, weight: Font.Weight) -> UIFont? {
        guard let name = faceName(for: weight), let font = UIFont(name: name, size: style.baseSize) else {
            return nil
        }
        return UIFontMetrics(forTextStyle: style.uiTextStyle).scaledFont(for: font)
    }
    #endif
}
#endif

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
