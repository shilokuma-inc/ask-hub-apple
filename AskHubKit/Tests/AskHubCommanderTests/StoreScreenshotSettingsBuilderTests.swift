@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// app-kit の撮影を使うアプリの撮影の設定を、`AppStore/` のファイルとリファレンスデータから組み立てる（#1303）
struct StoreScreenshotSettingsBuilderTests {
    typealias Builder = StoreScreenshotSettingsBuilder

    /// tm-family/shinkeisuijaku-app-ios の develop（52c224d）の `AppStore/screenshots.json`（説明と画面の並びは縮めた）
    static let screenshots = """
        {
          "_comment": ["App Store 用スクリーンショットの撮影設定。"],
          "scenes": [{ "file": "01_home", "scene": "home" }],
          "displayTypes": {
            "APP_IPHONE_61": { "label": "iPhone 6.3 inch", "deriveFrom": "APP_IPHONE_67", "sizes": ["1206x2622", "1179x2556"] },
            "APP_IPHONE_DUO": { "label": "iPhone Duo", "devices": ["iPhone Duo"], "sizes": ["1398x2034"], "runsOn": "xcode-27" },
            "APP_IPHONE_67": { "label": "iPhone 6.9 inch", "devices": ["iPhone 17 Pro Max"], "sizes": ["1320x2868"] },
            "APP_IPAD_PRO_3GEN_129": { "label": "iPad 13 inch", "devices": ["iPad Pro 13-inch (M5)"], "sizes": ["2064x2752"] }
          }
        }
        """
    /// shinkeisuijaku の `AppStore/languages.json`（日本語だけ）
    static let japanese = """
        {
          "_comment": ["App Store に載せる言語の単一定義。"],
          "languages": [{ "language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja" }]
        }
        """
    /// template-app-ios の `AppStore/languages.json`（日本語と英語）
    static let template = """
        {"languages": [
          { "language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja" },
          { "language": "en", "appleLanguage": "en", "appleLocale": "en_US", "storeLocale": "en-US" }
        ]}
        """

    /// リファレンスデータの配置グループ（6.9 inch のほかの id は文書に無いので、表示クラスの名前から当てた偽物）
    static let groups = [
        group("IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", "IPHONE_APP_STORE", "IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY"),
        group("IMESSAGE_IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", "IMESSAGE_APP_STORE", "IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY"),
        group("IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE", "IPHONE_APP_STORE", "IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY"),
        group("IPHONE_DUO_PROFILE", "IPHONE_APP_STORE", "IPHONE_DUO"),
        group("IPAD_13_PROFILE", "IPAD_APP_STORE", "IPAD_13_DISPLAY"),
        group("VISION_PRO_PROFILE", "VISION_PRO_APP_STORE"),
        group("MAC_PROFILE", "MAC_APP_STORE")
    ]

    static func group(_ id: String, _ platform: String, _ displayClass: String? = nil) -> AppStorePlacementProfileGroup {
        AppStorePlacementProfileGroup(id: id, platform: platform, displayClass: displayClass)
    }

    static let built = StoreScreenshotWorkflow(
        workflow: "app-store-screenshots.yml",
        artifacts: [
            "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": "APP_IPHONE_67",
            "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE": "APP_IPHONE_61",
            "IPHONE_DUO_PROFILE": "APP_IPHONE_DUO",
            "IPAD_13_PROFILE": "APP_IPAD_PRO_3GEN_129"
        ],
        languages: ["ja": .init(language: "ja")],
        baseLocale: "ja"
    )

    /// shinkeisuijaku の本物のファイルから、人が手で書いた設定（6.3 inch を除く）と同じ形を作る
    @Test func buildsSettingsFromTheFilesOfShinkeisuijaku() throws {
        let built = try Builder.build(screenshots: Self.screenshots, languages: Self.japanese, groups: Self.groups).get()
        #expect(built.workflow == Self.built && built.omitted.isEmpty)
        #expect(built.workflow.problems.isEmpty)
        #expect(Builder.summary(built.workflow) == "iPad 13 inch・iPhone 6.3 inch・iPhone 6.9 inch・iPhone Duo × ja")
    }

    /// 言語は languages.json の並び（先頭が基準の言語）。assetsFrom の言語は、流用元のフォルダを使う
    @Test func readsLanguagesWithAssetsFrom() throws {
        let built = try Builder.build(screenshots: Self.screenshots, languages: Self.template, groups: Self.groups).get()
        #expect(built.workflow.languages == ["ja": .init(language: "ja"), "en-US": .init(language: "en")])
        #expect(built.workflow.baseLocale == "ja")
        let ninjacord = """
            {"languages": [
              { "language": "en", "appleLanguage": "en", "appleLocale": "en_US", "storeLocale": "en-US" },
              { "language": "en-GB", "storeLocale": "en-GB", "assetsFrom": "en" }
            ]}
            """
        let reused = try Builder.build(screenshots: Self.screenshots, languages: ninjacord, groups: Self.groups).get().workflow
        #expect(reused.languages == ["en-US": .init(language: "en"), "en-GB": .init(language: "en")] && reused.baseLocale == "en-US")
    }

    /// 引けない名前は入れずにわけを返す。1 つも引けなければ作らない
    @Test func omitsSizesWithoutPlacementGroups() throws {
        let groups = Self.groups.filter { $0.displayClass != "IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY" }
        let built = try Builder.build(screenshots: Self.screenshots, languages: Self.japanese, groups: groups).get()
        #expect(built.workflow.artifacts.values.sorted() == ["APP_IPAD_PRO_3GEN_129", "APP_IPHONE_67", "APP_IPHONE_DUO"])
        #expect(built.omitted == [
            "撮影の設定: AppStore/screenshots.json の APP_IPHONE_61（iPhone 6.3 inch）を入れられない"
                + "（リファレンスデータに IPHONE_APP_STORE・IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY の配置グループが無い）"
        ])
        let none = Builder.build(screenshots: Self.screenshots, languages: Self.japanese, groups: [])
        #expect((try? none.get()) == nil)
        #expect(Self.problem(none)?.hasPrefix("撮影の設定: 作れない（配置グループを 1 つも引けない。") == true)
    }

    /// visionOS はプラットフォームだけで引く。知らない名前・同じ表示クラスの配置グループが 2 つあるときは入れない
    @Test func resolvesVisionProByPlatformAndRefusesUnknownOrAmbiguousSizes() throws {
        #expect(try Builder.placementGroup(for: "APP_APPLE_VISION_PRO", in: Self.groups).get() == "VISION_PRO_PROFILE")
        #expect(Self.problem(Builder.placementGroup(for: "APP_DESKTOP", in: Self.groups))?.contains("引き方を知らない") == true)
        let twice = Self.groups + [.init(id: "IPAD_13_OTHER_PROFILE", platform: "IPAD_APP_STORE", displayClass: "IPAD_13_DISPLAY")]
        #expect(Self.problem(Builder.placementGroup(for: "APP_IPAD_PRO_3GEN_129", in: twice))?.contains("2 つある") == true)
    }

    @Test func refusesFilesThatCannotBeRead() {
        #expect(Self.problem(Builder.build(screenshots: nil, languages: Self.japanese, groups: Self.groups))
            == "撮影の設定: 作れない（AppStore/screenshots.json が無い・読めない）")
        let empty = Builder.build(screenshots: "{}", languages: Self.japanese, groups: Self.groups)
        #expect(Self.problem(empty)?.contains("displayTypes") == true)
        let refused = { (languages: String) in
            Self.problem(Builder.build(screenshots: Self.screenshots, languages: languages, groups: Self.groups)) ?? ""
        }
        #expect(refused(#"{"languages":[{"language":"ja","storeLocale":"ja"},{"language":"jp","storeLocale":"ja"}]}"#).contains("重なる"))
        #expect(refused(#"{"languages":[{"language":"ja","storeLocale":"日本語"}]}"#).contains("言語"))
        #expect(refused(#"{"languages":[{"language":"en-GB","storeLocale":"en-GB","assetsFrom":"en"}]}"#).contains("assetsFrom"))
    }

    /// 人が書いた設定は書き換えず、リファレンスデータに無い配置グループと、screenshots.json にあって設定に無い名前を知らせる
    @Test func reportsProblemsOfHandWrittenSettings() {
        var handWritten = Self.built
        handWritten.artifacts["IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE"] = nil
        handWritten.artifacts["IPAD_13_PROFILE"] = nil
        handWritten.artifacts["IPAD_PRO_13_PROFILE"] = "APP_IPAD_PRO_3GEN_129"
        #expect(Builder.problems(of: handWritten, screenshots: Self.screenshots, groups: Self.groups) == [
            "撮影の設定: build.storeScreenshots.artifacts の配置グループ IPAD_PRO_13_PROFILE が App Store Connect のリファレンスデータに無い。"
                + "APP_IPAD_PRO_3GEN_129 は IPAD_13_PROFILE",
            "撮影の設定: AppStore/screenshots.json の APP_IPHONE_61（iPhone 6.3 inch）が build.storeScreenshots.artifacts に無い"
                + "（足すなら IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE）"
        ])
        #expect(Builder.problems(of: Self.built, screenshots: Self.screenshots, groups: Self.groups).isEmpty)
    }

    /// 配置グループと表示サイズの組み合わせの入れ替わりと、screenshots.json が無い・読めないことも知らせる
    @Test func reportsSwappedSizesAndUnreadableScreenshots() {
        var swapped = Self.built
        swapped.artifacts["IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"] = "APP_IPHONE_61"
        swapped.artifacts["IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE"] = "APP_IPHONE_67"
        #expect(Builder.problems(of: swapped, screenshots: Self.screenshots, groups: Self.groups) == [
            "撮影の設定: build.storeScreenshots.artifacts の配置グループ IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE に APP_IPHONE_61（iPhone 6.3 inch）を撮っている"
                + "（APP_IPHONE_61 は IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE）",
            "撮影の設定: build.storeScreenshots.artifacts の配置グループ IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE に APP_IPHONE_67（iPhone 6.9 inch）を撮っている"
                + "（APP_IPHONE_67 は IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE）"
        ])
        #expect(Builder.problems(of: Self.built, screenshots: nil, groups: Self.groups) == ["撮影の設定: AppStore/screenshots.json が無い・読めない"])
        #expect(Builder.problems(of: Self.built, screenshots: "{}", groups: Self.groups)
            == ["撮影の設定: AppStore/screenshots.json の displayTypes を読めない"])
    }

    static func problem<Value>(_ result: Result<Value, Builder.Problem>) -> String? {
        guard case let .failure(problem) = result else { return nil }
        return problem.description
    }
}
