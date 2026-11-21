import Foundation

/// App Store のスクショの撮り方（`repo.json` の `build.storeScreenshots`。`docs/renewal/release.md` の「スクショ」）。無いリポジトリでは撮らない。
///
/// 司令塔が release ブランチの先頭で、リポジトリの UI テスト（`test`）を表示サイズ・言語ごとに流し、テストが添付した画像（`XCTAttachment`）を
/// 添付した順に、App Store の 1 枚目・2 枚目… として使う。テストはデモのデータで開き、言語は環境変数で受け取る
public struct StoreScreenshotSettings: Codable, Equatable, Sendable {
    /// 1 つの組（表示サイズ・言語）に入れられるスクショの数の上限（App Store Connect の上限）
    public static let maximumShots = 10

    /// アプリの言語と地域（テストに環境変数で渡す）
    public struct Language: Codable, Equatable, Sendable {
        /// アプリの言語（`-AppleLanguages` に渡す値。`ja`・`en`・`zh-Hans` など）。前に配信した版から文言が変わった言語（`.lproj` のフォルダ・
        /// String Catalog の言語）と結ぶのにも使う
        public var language: String
        /// 地域（`-AppleLocale` に渡す値。`ja_JP` など）。無ければ渡さない
        public var region: String?

        public init(language: String, region: String? = nil) {
            self.language = language
            self.region = region
        }
    }

    /// 流す UI テスト（`xcodebuild test -only-testing:` の値。`OshiConUITests/AppStoreScreenshotTests/testCaptureAppStoreScreenshots`）
    public var test: String
    /// テストに渡す決まった環境変数（`APP_STORE_SCREENSHOTS=1` など。xcodebuild には `TEST_RUNNER_` を付けて渡す）
    public var environment: [String: String]
    /// 言語を渡す環境変数の名前（値は `languages` の `language`）
    public var languageVariable: String
    /// 地域を渡す環境変数の名前（値は `languages` の `region`）。無ければ渡さない
    public var regionVariable: String?
    /// App Store Connect の言語（`ja`・`en-US` など）ごとの、アプリの言語と地域。ここに無い言語は撮らない
    public var languages: [String: Language]
    /// 基準の言語（App Store Connect の言語）。毎回撮り、ほかの言語は基準の言語で差が出たときか、その言語の文言が前に配信した版から変わったときだけ撮る
    public var baseLocale: String
    /// App Store Connect の表示サイズ（App Asset Library の配置グループ。`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など）ごとの、
    /// 撮る Simulator の機種の名前（上から順に、ある機種を使う）。
    /// App Store Connect にあってここに無い表示サイズは、撮れない表示サイズとして知らせる
    public var displayTypes: [String: [String]]

    public init(
        test: String,
        environment: [String: String] = [:],
        languageVariable: String,
        regionVariable: String? = nil,
        languages: [String: Language],
        baseLocale: String,
        displayTypes: [String: [String]]
    ) {
        self.test = test
        self.environment = environment
        self.languageVariable = languageVariable
        self.regionVariable = regionVariable
        self.languages = languages
        self.baseLocale = baseLocale
        self.displayTypes = displayTypes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decode(String.self, forKey: .test)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        languageVariable = try container.decode(String.self, forKey: .languageVariable)
        regionVariable = try container.decodeIfPresent(String.self, forKey: .regionVariable)
        languages = try container.decode([String: Language].self, forKey: .languages)
        baseLocale = try container.decode(String.self, forKey: .baseLocale)
        displayTypes = try container.decode([String: [String]].self, forKey: .displayTypes)
    }

    /// 型だけでは表せない決まりに合わないところ
    public var problems: [String] {
        var problems: [String] = []
        let field = "build.storeScreenshots"
        if test.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*){1,2}/#) == nil {
            problems.append("\(field).test は <テストのターゲット>/<クラス>[/<メソッド>] の形")
        }
        let variables = Array(environment.keys) + [languageVariable] + (regionVariable.map { [$0] } ?? [])
        if !variables.allSatisfy(Self.isVariable) || Set(variables).count != variables.count {
            problems.append("\(field) の環境変数の名前は英大文字・数字・_ で、重ならない")
        }
        if !environment.values.allSatisfy(Self.isValue) { problems.append("\(field).environment の値は 200 文字まで・制御文字なし") }
        if languages.isEmpty || languages.count > LocalizedText.localeLimit {
            problems.append("\(field).languages は 1〜\(LocalizedText.localeLimit) 個")
        }
        if !languages.keys.allSatisfy(LocalizedText.isLocale) { problems.append("\(field).languages のキーは App Store Connect の言語") }
        if !languages.values.allSatisfy({ Self.isAppLanguage($0.language) && ($0.region.map(Self.isAppLanguage) ?? true) }) {
            problems.append("\(field).languages の language・region は英数字と - _ で 20 文字まで")
        }
        if languages[baseLocale] == nil { problems.append("\(field).baseLocale は languages にある言語") }
        if displayTypes.isEmpty || !displayTypes.keys.allSatisfy(Self.isDisplayType) {
            problems.append("\(field).displayTypes は 1 つ以上で、キーは App Store Connect の表示サイズ（英大文字・数字・_）")
        }
        if displayTypes.values.contains(where: { $0.isEmpty || $0.count > 10 || !$0.allSatisfy(Self.isValue) }) {
            problems.append("\(field).displayTypes の機種は 1〜10 個の、空でない名前")
        }
        return problems
    }

    /// 環境変数の名前（英大文字で始まり、英大文字・数字・_ で 60 文字まで）
    static func isVariable(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Z][A-Z0-9_]{0,59}/#) != nil
    }

    /// App Store Connect の表示サイズ（App Asset Library の配置グループ。`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など）
    public static func isDisplayType(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Z][A-Z0-9_]{1,59}/#) != nil
    }

    private static func isAppLanguage(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9_-]{1,20}/#) != nil
    }

    private static func isValue(_ text: String) -> Bool {
        (1...200).contains(text.unicodeScalars.count) && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
