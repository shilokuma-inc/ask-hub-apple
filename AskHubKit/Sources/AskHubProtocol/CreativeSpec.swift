import Foundation

/// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の種類（`docs/renewal/creative-assets.md`）
public enum CreativeKind: String, Codable, CaseIterable, Sendable {
    /// プロダクトページのヘッダー（21:9。3840x1646・PNG）。App Store Connect の配置の種類は `PRODUCT_PAGE_HEADER_ASSET`
    case productPageHeader
    /// 検索結果（3:2。3840x2560 で書き出す）。配置の種類は `APP_STORE_SEARCH_RESULTS_ASSET`
    case searchResults

    /// 書き出す寸法（app-kit の `tools/creative/render_creative.py` と同じ）
    public var size: (width: Int, height: Int) {
        switch self {
        case .productPageHeader: (3840, 1646)
        case .searchResults: (3840, 2560)
        }
    }

    /// artifact `creative-assets` の中のファイルの名前（`<言語>/<名前>`）
    public var fileName: String {
        switch self {
        case .productPageHeader: "product-page-header.png"
        case .searchResults: "search-results.png"
        }
    }

    /// App Asset Library の配置の種類（`placementType`）
    public var placementType: String {
        switch self {
        case .productPageHeader: "PRODUCT_PAGE_HEADER_ASSET"
        case .searchResults: "APP_STORE_SEARCH_RESULTS_ASSET"
        }
    }
}

/// 書き出しを止めない問題（文字のはみ出し・安全領域の外の文字・Apple の決まりに合わない文言・低いコントラストなど）。
/// `code` は app-kit の `report.json` と同じ（`text-overflow`・`outside-safe-area`・`image-missing`・`forbidden-url` など）
public struct CreativeProblem: Codable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// 記録に書ける形か（app-kit の `report.json` から写すときに確かめる）
    public var isWellFormed: Bool { problems.isEmpty }

    var problems: [String] {
        var problems: [String] = []
        if code.wholeMatch(of: #/[a-z][a-z0-9-]{0,39}/#) == nil { problems.append("問題の code の形が違う") }
        if message.isEmpty || message.unicodeScalars.count > 500 { problems.append("問題の message は 1〜500 文字") }
        return problems
    }
}

/// クリエイティブアセットの案（文言・色・使う画面）。app-kit の `schema/creative-spec.schema.json` と同じ形で、
/// 司令塔が書き出しのワークフロー（`app-store-creative.yml`）の入力 `spec` に JSON の文字列で渡す。
/// 決まりは app-kit の `tools/creative/creative_spec.py` と同じにする（形の誤りは `violations`、書き出しを止めない問題は `cautions`）
public struct CreativeSpec: Codable, Equatable, Sendable {
    /// 雛形の配置の種類
    public enum Layout: String, Codable, Sendable {
        /// ヘッダーは中央の見出しと 3 台の端末、検索結果は左に文言と右に 2 台の端末
        case standard
    }

    public struct Colors: Codable, Equatable, Sendable {
        /// 背景（上）
        public var background: String
        /// 背景（下）。省くと `background` だけ
        public var background2: String?
        /// チップの色
        public var accent: String
        /// 強調（`*` で囲んだ文字）とアプリ名の色。省くと `accent`
        public var highlight: String?
        /// 文字の色
        public var text: String

        public init(background: String, background2: String? = nil, accent: String, highlight: String? = nil, text: String) {
            self.background = background
            self.background2 = background2
            self.accent = accent
            self.highlight = highlight
            self.text = text
        }
    }

    /// 端末に載せる画面（撮影の artifact のファイル名から `.png` を除いたもの）
    public struct Screens: Codable, Equatable, Sendable {
        /// 中央・左・右の順（1〜3 個）
        public var header: [String]
        /// 手前・奥の順（1〜2 個）
        public var search: [String]

        public init(header: [String], search: [String]) {
            self.header = header
            self.search = search
        }
    }

    public struct Header: Codable, Equatable, Sendable {
        /// 見出し（2 行まで）
        public var title: String
        /// 見出しを支える一文
        public var subtitle: String?

        public init(title: String, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Search: Codable, Equatable, Sendable {
        /// 何をするアプリか（3 行まで）
        public var title: String
        /// 主な機能（3 つまで）
        public var chips: [String]?

        public init(title: String, chips: [String]? = nil) {
            self.title = title
            self.chips = chips
        }
    }

    /// App Store Connect の言語ごとの文言
    public struct Localization: Codable, Equatable, Sendable {
        /// App Store Connect の言語（`ja`・`en-US` など）
        public var locale: String
        /// 撮影の artifact のこの言語のフォルダ（`build.storeScreenshots.languages` の `language`）
        public var screenshots: String
        /// アプリ名（App Store Connect の名前）
        public var appName: String
        public var header: Header
        public var search: Search

        public init(locale: String, screenshots: String, appName: String, header: Header, search: Search) {
            self.locale = locale
            self.screenshots = screenshots
            self.appName = appName
            self.header = header
            self.search = search
        }
    }

    /// 形の版（app-kit の案の `v`）
    public static let formatVersion = 1
    /// 1 つの案に持てる言語の数
    public static let localeLimit = 50
    /// 文言の長さの上限（Unicode のスカラーの数。app-kit の Python の `len` と同じ数え方）
    public static let limits: [String: Int] = [
        "appName": 30, "header.title": 60, "header.subtitle": 90, "search.title": 60, "search.chips": 30
    ]
    /// 1 つの文言に入れられる改行の数
    public static let newlineLimit = 2

    /// 形の版（JSON では `v`）
    public var version: Int
    public var layout: Layout
    public var colors: Colors
    public var screens: Screens
    public var locales: [Localization]

    public init(layout: Layout = .standard, colors: Colors, screens: Screens, locales: [Localization]) {
        self.version = Self.formatVersion
        self.layout = layout
        self.colors = colors
        self.screens = screens
        self.locales = locales
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case layout
        case colors
        case screens
        case locales
    }

    /// 書き出せない形の誤り。空なら書き出せる
    public var violations: [String] {
        var problems: [String] = []
        if version != Self.formatVersion { problems.append("案の v は \(Self.formatVersion)") }
        let colorValues = [colors.background, colors.background2, colors.accent, colors.highlight, colors.text].compactMap(\.self)
        if !colorValues.allSatisfy(Self.isColor) { problems.append("案の色は #RRGGBB") }
        if !(1...3).contains(screens.header.count) { problems.append("screens.header は 1〜3 個") }
        if !(1...2).contains(screens.search.count) { problems.append("screens.search は 1〜2 個") }
        if !(screens.header + screens.search).allSatisfy(Self.isScreen) { problems.append("screens の画面の名前の形が違う") }
        if !(1...Self.localeLimit).contains(locales.count) { problems.append("locales は 1〜\(Self.localeLimit) 個") }
        if Set(locales.map(\.locale)).count != locales.count { problems.append("locales の言語が重なっている") }
        for localization in locales {
            let code = localization.locale
            if !LocalizedText.isLocale(code) { problems.append("\(code) は App Store Connect の言語でない") }
            if !Self.isFolder(localization.screenshots) { problems.append("\(code) の screenshots の形が違う") }
            if let chips = localization.search.chips, chips.count > 3 { problems.append("\(code) の search.chips は 3 つまで") }
            for field in Self.texts(of: localization) {
                problems += Self.textProblems(field.text, name: "\(code).\(field.name)", allowEmpty: field.allowEmpty)
            }
        }
        return problems
    }

    /// 書き出しは止めない問題（Apple の決まりに合わない文言・低いコントラスト）。app-kit の `report.json` の `problems` と同じ code
    public var cautions: [CreativeProblem] {
        var cautions: [CreativeProblem] = []
        for localization in locales {
            for field in Self.texts(of: localization) {
                for rule in Self.forbidden where rule.matches(field.text) {
                    let message = "\(localization.locale).\(field.name) に\(rule.what)らしい文字があります（App Store の決まりで入れられません）"
                    cautions.append(.init(code: rule.code, message: message))
                }
            }
        }
        for background in Set([colors.background, colors.background2 ?? colors.background]).sorted() {
            guard Self.isColor(colors.text), Self.isColor(background) else { continue }
            let ratio = Self.contrast(colors.text, background)
            if ratio < 4.5 {
                cautions.append(.init(
                    code: "low-contrast",
                    message: "文字の色と背景の色 \(background) のコントラストが \(String(format: "%.1f", ratio)) で、4.5 より低いです"
                ))
            }
        }
        return cautions
    }

    /// 書き出しのワークフローの入力に入れる JSON の文字列（1 行。キーを並べる）
    public func inputJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let text = String(bytes: try encoder.encode(self), encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "案を UTF-8 の文字列にできない"))
        }
        return text
    }

    // MARK: - 決まり

    public static func isColor(_ text: String) -> Bool { text.wholeMatch(of: #/#[0-9A-Fa-f]{6}/#) != nil }
    public static func isScreen(_ text: String) -> Bool { text.wholeMatch(of: #/[A-Za-z0-9_-]{1,64}/#) != nil }
    public static func isFolder(_ text: String) -> Bool { text.wholeMatch(of: #/[A-Za-z0-9_-]{1,20}/#) != nil }

    /// 言語の 1 つの文言
    struct TextField {
        var name: String
        var text: String
        /// 空でよい（一文）
        var allowEmpty = false
    }

    static func texts(of localization: Localization) -> [TextField] {
        var texts = [
            TextField(name: "appName", text: localization.appName),
            TextField(name: "header.title", text: localization.header.title)
        ]
        if let subtitle = localization.header.subtitle { texts.append(.init(name: "header.subtitle", text: subtitle, allowEmpty: true)) }
        texts.append(.init(name: "search.title", text: localization.search.title))
        for (index, chip) in (localization.search.chips ?? []).enumerated() {
            texts.append(.init(name: "search.chips[\(index)]", text: chip))
        }
        return texts
    }

    static func textProblems(_ text: String, name: String, allowEmpty: Bool) -> [String] {
        let limitName = name.split(separator: ".", maxSplits: 1).last.map { String($0).replacing(#/\[\d+\]/#, with: "") } ?? name
        let limit = limits[limitName] ?? 30
        var problems: [String] = []
        if !allowEmpty, text.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(name) が空") }
        if text.unicodeScalars.count > limit { problems.append("\(name) は \(limit) 文字まで") }
        let control = text.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n") || $0.value == 0x7F }
        if control { problems.append("\(name) に制御文字がある") }
        if text.filter({ $0 == "\n" }).count > newlineLimit { problems.append("\(name) の改行は \(newlineLimit) つまで") }
        if !text.filter({ $0 == "*" }).count.isMultiple(of: 2) { problems.append("\(name) の強調の * が閉じていない") }
        return problems
    }

    /// Apple の決まりで入れられない文字の決まり
    struct ForbiddenRule: Sendable {
        var code: String
        var matches: @Sendable (String) -> Bool
        /// 理由に書く名前
        var what: String
    }

    /// Apple の決まりで入れられない文字（app-kit の `creative_spec.py` の `FORBIDDEN` と同じ）
    static let forbidden: [ForbiddenRule] = [
        .init(
            code: "forbidden-url",
            matches: { $0.contains(#/(?i)(https?:\/\/|www\.|\b[a-z0-9-]+\.(com|net|org|jp|app|io)\b)/#) },
            what: "URL"
        ),
        .init(code: "forbidden-email", matches: { $0.contains(#/[\w.+-]+@[\w-]+\.[\w.]+/#) }, what: "メールアドレス"),
        .init(code: "forbidden-symbol", matches: { $0.contains(#/[©®™℗]/#) }, what: "著作権・商標の記号"),
        .init(
            code: "forbidden-price",
            matches: { $0.contains(#/(?i)([¥$€£₩₹]\s?\d|\d\s?(円|ドル|元|원)|\bfree\b|無料)/#) },
            what: "価格"
        )
    ]

    /// WCAG のコントラスト比
    static func contrast(_ first: String, _ second: String) -> Double {
        let values = [luminance(first), luminance(second)].sorted(by: >)
        return (values[0] + 0.05) / (values[1] + 0.05)
    }

    private static func luminance(_ color: String) -> Double {
        let hex = color.dropFirst()
        let channels = stride(from: 0, to: 6, by: 2).map { offset -> Double in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let value = Double(Int(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
