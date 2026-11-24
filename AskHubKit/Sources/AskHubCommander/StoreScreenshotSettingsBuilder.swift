import AskHubProtocol
import Foundation

/// app-kit の撮影のワークフローで撮るアプリの、撮影の設定（`build.storeScreenshots` の `capture: actions`）を、リポジトリの `AppStore/` の
/// ファイルと App Store Connect のリファレンスデータから組み立てる（`docs/renewal/store-screenshots.md` の「設定の組み立て」）。
///
/// - `workflow` は app-kit の写すファイル（`app-store-screenshots.yml`）。リポジトリのファイルからは読まない
/// - `artifacts` は `AppStore/screenshots.json` の表示サイズの名前ごとに、配置のプラットフォームと表示クラスでリファレンスデータの配置グループを引く
///   （配置グループの id は文書に無いものが多く、Apple は決め打ちしないよう求めている）。1 つに決まらない名前は入れず、わけを返す
/// - `languages` は `AppStore/languages.json` の並びの `storeLocale` → `language`（`assetsFrom` を書いた言語は、流用元の言語のフォルダ）。
///   `baseLocale` は先頭の言語
enum StoreScreenshotSettingsBuilder {
    static let workflow = "app-store-screenshots.yml"
    static let workflowPath = ".github/workflows/\(workflow)"
    static let screenshotsPath = "AppStore/screenshots.json"
    static let languagesPath = "AppStore/languages.json"
    /// ずれ（`appKit.drift`）に書く撮影の設定の問題の頭。ずれの点検で、ほかのずれと見分ける
    static let problemPrefix = "撮影の設定: "

    /// 表示サイズの名前で引く配置グループ
    struct Target: Equatable {
        /// 呼び名（人が読む文に出す）
        var label: String
        /// 配置のプラットフォーム（`AppAssetLibraryPlacementPlatform`）
        var platform: String
        /// 表示クラス（`AppAssetLibraryDisplayClass`）。nil ならプラットフォームだけで引く（Vision Pro には表示クラスが無い）
        var displayClass: String?
    }

    /// app-kit が撮る表示サイズの名前（`AppStore/screenshots.json` の `displayTypes` のキー）と、引く配置グループ。
    /// 表示クラスの値は Apple の文書（`AppAssetLibraryDisplayClass`）にある
    static let targets: [String: Target] = [
        "APP_IPHONE_67": .init(label: "iPhone 6.9 inch", platform: iPhone, displayClass: "IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY"),
        "APP_IPHONE_61": .init(label: "iPhone 6.3 inch", platform: iPhone, displayClass: "IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY"),
        "APP_IPHONE_DUO": .init(label: "iPhone Duo", platform: iPhone, displayClass: "IPHONE_DUO"),
        "APP_IPAD_PRO_3GEN_129": .init(label: "iPad 13 inch", platform: "IPAD_APP_STORE", displayClass: "IPAD_13_DISPLAY"),
        "APP_APPLE_VISION_PRO": .init(label: "Apple Vision Pro", platform: "VISION_PRO_APP_STORE")
    ]
    private static let iPhone = "IPHONE_APP_STORE"

    struct Built: Equatable {
        var workflow: StoreScreenshotWorkflow
        /// 入れられなかった名前のわけ（`problemPrefix` 付きの、人が読む文）
        var omitted: [String]
    }

    /// 組み立てる。作れなければ、わけ（`problemPrefix` 付きの、人が読む文）
    static func build(screenshots: String?, languages: String?, groups: [AppStorePlacementProfileGroup]) -> Result<Built, Problem> {
        guard let screenshots else { return .failure(.init("作れない（\(screenshotsPath) が無い・読めない）")) }
        guard let languages else { return .failure(.init("作れない（\(languagesPath) が無い・読めない）")) }
        guard let names = names(in: screenshots) else {
            return .failure(.init("作れない（\(screenshotsPath) の displayTypes を読めない）"))
        }
        let parsed: (languages: [String: StoreScreenshotSettings.Language], base: String)
        switch self.languages(in: languages) {
        case let .success(made): parsed = made
        case let .failure(problem): return .failure(problem)
        }
        var artifacts: [String: String] = [:]
        var omitted: [String] = []
        for name in names {
            switch placementGroup(for: name, in: groups) {
            case let .success(group): artifacts[group] = name
            case let .failure(problem): omitted.append(problem.description)
            }
        }
        guard !artifacts.isEmpty else {
            let reasons = omitted.map { String($0.dropFirst(problemPrefix.count)) }.joined(separator: "。")
            return .failure(.init("作れない（配置グループを 1 つも引けない。\(reasons)）"))
        }
        let workflow = StoreScreenshotWorkflow(
            workflow: workflow, artifacts: artifacts, languages: parsed.languages, baseLocale: parsed.base
        )
        if let problem = workflow.problems.first { return .failure(.init("作れない（\(problem)）")) }
        return .success(Built(workflow: workflow, omitted: omitted))
    }

    /// 今の設定と、リポジトリの `AppStore/screenshots.json`・リファレンスデータとの食い違い（`problemPrefix` 付きの、人が読む文）。
    /// 人が書いた設定は書き換えないので、知らせるだけにする
    static func problems(of workflow: StoreScreenshotWorkflow, screenshots: String?, groups: [AppStorePlacementProfileGroup]) -> [String] {
        var problems: [String] = []
        let known = Set(groups.map(\.id))
        for (group, name) in workflow.artifacts.sorted(by: { $0.key < $1.key }) where !known.contains(group) {
            let hint = (try? placementGroup(for: name, in: groups).get()).map { "。\(name) は \($0)" } ?? ""
            problems.append(problemPrefix + "build.storeScreenshots.artifacts の配置グループ \(group) が App Store Connect のリファレンスデータに無い\(hint)")
        }
        let configured = Set(workflow.artifacts.values)
        for name in screenshots.flatMap(names(in:)) ?? [] where !configured.contains(name) {
            switch placementGroup(for: name, in: groups) {
            case let .success(group):
                problems.append(problemPrefix + "\(screenshotsPath) の \(label(name))が build.storeScreenshots.artifacts に無い（足すなら \(group)）")
            case let .failure(problem):
                problems.append(problem.description)
            }
        }
        return problems
    }

    /// 表示サイズの名前の配置グループ。1 つに決まらなければ、わけ
    static func placementGroup(for name: String, in groups: [AppStorePlacementProfileGroup]) -> Result<String, Problem> {
        guard let target = targets[name] else {
            return .failure(.init("\(screenshotsPath) の \(name) を入れられない（AskHub が配置グループの引き方を知らない表示サイズ）"))
        }
        let matched = groups.filter { group in
            group.platform == target.platform && (target.displayClass == nil || group.displayClass == target.displayClass)
        }
        let ids = Set(matched.map(\.id)).sorted()
        guard ids.count == 1, let id = ids.first else {
            let key = [target.platform, target.displayClass].compactMap { $0 }.joined(separator: "・")
            let found = ids.isEmpty ? "無い" : "\(ids.count) つある（\(ids.joined(separator: "・"))）"
            return .failure(.init("\(screenshotsPath) の \(label(name))を入れられない（リファレンスデータに \(key) の配置グループが\(found)）"))
        }
        return .success(id)
    }

    /// `screenshots.json` の表示サイズの名前（名前の順）。読めなければ nil
    static func names(in text: String) -> [String]? {
        struct File: Decodable {
            let displayTypes: [String: Ignored]
        }
        struct Ignored: Decodable {}
        guard let file = try? JSONDecoder().decode(File.self, from: Data(text.utf8)) else { return nil }
        return file.displayTypes.keys.sorted()
    }

    /// `languages.json` の 1 つの言語
    private struct LanguageEntry: Decodable {
        let language: String
        let storeLocale: String
        let assetsFrom: String?
    }

    /// `languages.json` の言語（App Store Connect の言語 → artifact のフォルダ）と、基準の言語（先頭）
    static func languages(in text: String) -> Result<(languages: [String: StoreScreenshotSettings.Language], base: String), Problem> {
        struct File: Decodable {
            let languages: [LanguageEntry]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: Data(text.utf8)) else {
            return .failure(.init("作れない（\(languagesPath) の languages を読めない）"))
        }
        guard let base = file.languages.first?.storeLocale else { return .failure(.init("作れない（\(languagesPath) に言語が無い）")) }
        let folders = Set(file.languages.map(\.language))
        var languages: [String: StoreScreenshotSettings.Language] = [:]
        for entry in file.languages {
            if let source = entry.assetsFrom, !folders.contains(source) {
                return .failure(.init("作れない（\(languagesPath) の \(entry.language) の assetsFrom（\(source)）が無い言語）"))
            }
            guard languages[entry.storeLocale] == nil else {
                return .failure(.init("作れない（\(languagesPath) の storeLocale \(entry.storeLocale) が重なる）"))
            }
            languages[entry.storeLocale] = .init(language: entry.assetsFrom ?? entry.language)
        }
        return .success((languages, base))
    }

    /// 人が読む表示サイズの名前（`APP_IPHONE_61（iPhone 6.3 inch）`。全角の括弧で終わるので、後ろに空白を入れずに続ける）
    static func label(_ name: String) -> String {
        targets[name].map { "\(name)（\($0.label)）" } ?? name
    }

    /// 作った設定の要約（ログに出す。`iPhone 6.9 inch・iPad 13 inch × ja・en-US`）
    static func summary(_ workflow: StoreScreenshotWorkflow) -> String {
        let sizes = workflow.artifacts.values.sorted().map { targets[$0]?.label ?? $0 }.joined(separator: "・")
        let locales = workflow.languages.keys.sorted { lhs, rhs in
            lhs == workflow.baseLocale || (rhs != workflow.baseLocale && lhs < rhs)
        }
        return "\(sizes) × \(locales.joined(separator: "・"))"
    }

    struct Problem: Error, Equatable, CustomStringConvertible {
        var description: String

        /// `problemPrefix` を付ける
        init(_ message: String) {
            description = message.hasPrefix(StoreScreenshotSettingsBuilder.problemPrefix) ? message
                : StoreScreenshotSettingsBuilder.problemPrefix + message
        }
    }
}
