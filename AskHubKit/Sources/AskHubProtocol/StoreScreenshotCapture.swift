import Foundation

/// App Store のスクショの撮り方（`repo.json` の `build.storeScreenshots`。`docs/renewal/store-screenshots.md`）。
/// `capture` で分け、無ければ `uiTest`（今までの形）として読む。書き出すときは `capture` をいつも書く
/// （ビルドの設定の意図は、読んだ値を書き直したものに送った値が含まれるかで知らない欄を断るので、送った `capture` を落とさない）
public enum StoreScreenshotCapture: Codable, Equatable, Sendable {
    /// 常時オンの Mac の司令塔が、リポジトリの UI テストを流して添付の画像を取り出す（#1173）
    case uiTest(StoreScreenshotSettings)
    /// リポジトリの撮影のワークフロー（GitHub Actions）を起動し、artifact を取り込む
    case actions(StoreScreenshotWorkflow)

    /// 撮り方の種類（`capture` の値）
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case uiTest
        case actions
    }

    public var kind: Kind {
        switch self {
        case .uiTest: .uiTest
        case .actions: .actions
        }
    }

    /// 基準の言語（App Store Connect の言語）
    public var baseLocale: String {
        switch self {
        case let .uiTest(settings): settings.baseLocale
        case let .actions(workflow): workflow.baseLocale
        }
    }

    /// 型だけでは表せない決まりに合わないところ
    public var problems: [String] {
        switch self {
        case let .uiTest(settings): settings.problems
        case let .actions(workflow): workflow.problems
        }
    }

    private enum CodingKeys: String, CodingKey {
        case capture
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .capture) ?? .uiTest {
        case .uiTest: self = .uiTest(try StoreScreenshotSettings(from: decoder))
        case .actions: self = .actions(try StoreScreenshotWorkflow(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .capture)
        switch self {
        case let .uiTest(settings): try settings.encode(to: encoder)
        case let .actions(workflow): try workflow.encode(to: encoder)
        }
    }
}

/// リポジトリの撮影のワークフローで撮る設定（`capture: actions`。`docs/renewal/store-screenshots.md` の「撮り方の設定」）。
///
/// 司令塔が、リリースを始めた版の release ブランチで `workflow` を `upload: false` で起動し、artifact（`screenshots-<表示サイズ>`。
/// 中身は `<言語>/<名前>.png`）を取り込む。template 系の `.github/workflows/app-store-screenshots.yml` の形
public struct StoreScreenshotWorkflow: Codable, Equatable, Sendable {
    /// `.github/workflows/` の下のワークフローのファイル名（`app-store-screenshots.yml`）
    public var workflow: String
    /// App Store Connect の表示サイズ（App Asset Library の配置グループ）ごとの、artifact の表示サイズの名前（`APP_IPHONE_67` など。
    /// artifact は `screenshots-<名前>`）。ワークフローの入力 `display_types` にもこの名前を渡す
    public var artifacts: [String: String]
    /// App Store Connect の言語ごとの、artifact のフォルダの言語（template の `AppStore/languages.json` の `language`）。ここに無い言語は取り込まない
    public var languages: [String: StoreScreenshotSettings.Language]
    /// 基準の言語（App Store Connect の言語）。クライアントで Before / After を 1 枚ずつ見せる
    public var baseLocale: String

    public init(workflow: String, artifacts: [String: String], languages: [String: StoreScreenshotSettings.Language], baseLocale: String) {
        self.workflow = workflow
        self.artifacts = artifacts
        self.languages = languages
        self.baseLocale = baseLocale
    }

    private enum CodingKeys: String, CodingKey {
        case workflow, artifacts, languages, baseLocale
    }

    /// 型だけでは表せない決まりに合わないところ
    public var problems: [String] {
        var problems: [String] = []
        let field = "build.storeScreenshots"
        if !Self.isWorkflowFile(workflow) { problems.append("\(field).workflow は .github/workflows/ の下の .yml・.yaml のファイル名") }
        if artifacts.isEmpty || artifacts.count > 20 || !artifacts.keys.allSatisfy(StoreScreenshotSettings.isDisplayType) {
            problems.append("\(field).artifacts は 1〜20 個で、キーは App Store Connect の表示サイズ（App Asset Library の配置グループ）")
        }
        if !artifacts.values.allSatisfy(Self.isArtifactName) {
            problems.append("\(field).artifacts の値は artifact の表示サイズの名前（英数字・_・- で 60 文字まで）")
        }
        if languages.isEmpty || languages.count > LocalizedText.localeLimit {
            problems.append("\(field).languages は 1〜\(LocalizedText.localeLimit) 個")
        }
        if !languages.keys.allSatisfy(LocalizedText.isLocale) { problems.append("\(field).languages のキーは App Store Connect の言語") }
        if !languages.values.allSatisfy({ Self.isFolder($0.language) && $0.region == nil }) {
            problems.append("\(field).languages の language は artifact のフォルダの名前（英数字と - _ で 20 文字まで）で、region は持たない")
        }
        if languages[baseLocale] == nil { problems.append("\(field).baseLocale は languages にある言語") }
        return problems
    }

    /// ワークフローのファイル名（`.github/workflows/` の直下。英数字で始まり、英数字・. _ - で 100 文字まで、拡張子は .yml か .yaml）
    public static func isWorkflowFile(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._-]{0,94}\.ya?ml/#) != nil && !text.contains("..")
    }

    /// artifact の表示サイズの名前（`APP_IPHONE_67` など）
    public static func isArtifactName(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_-]{0,59}/#) != nil
    }

    /// artifact のフォルダの言語（`ja`・`en`・`zh-Hans` など）
    static func isFolder(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9_-]{1,20}/#) != nil
    }
}
