import Foundation

/// 判断のカードのスクショの撮り方（`repo.json` の `build.screenshots`。`docs/renewal/flows.md` の「スクショ」）。無いリポジトリでは撮らない。
///
/// ワーカーは、リポジトリの撮れる画面の一覧（`scenes` のファイル。`ScreenshotScenesFile`）の起動引数でアプリを Simulator に起動して撮る
public struct ScreenshotSettings: Codable, Equatable, Sendable {
    /// 撮れる画面の一覧のファイルの、リポジトリの直下からの相対パス（base と作業ブランチの先頭のそれぞれから読む）
    public var scenes: String
    /// 撮る Simulator（`{"platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "27.0"}` の形。macOS はまだ撮らない）
    public var destination: BuildDestination

    public init(scenes: String, destination: BuildDestination) {
        self.scenes = scenes
        self.destination = destination
    }

    /// 撮る Simulator。macOS なら nil
    public var simulator: SimulatorDestination? {
        guard case .simulator(let simulator) = destination else { return nil }
        return simulator
    }

    /// 型だけでは表せない決まりに合わないところ
    public var problems: [String] {
        var problems: [String] = []
        do {
            try BuildSettings.checkRelativePath(scenes, field: "screenshots.scenes")
            try destination.validate()
        } catch {
            problems.append("build.screenshots: \(error.description)")
        }
        if !scenes.hasSuffix(".json") { problems.append("build.screenshots.scenes は JSON のファイルを指す") }
        if simulator == nil { problems.append("build.screenshots.destination は Simulator（iOS・visionOS）。macOS はまだ撮らない") }
        return problems
    }
}

/// リポジトリに置く、撮れる画面の一覧（`build.screenshots.scenes` のファイル）。
///
/// 1 画面ごとに、名前・説明と、その画面をデモのデータで開く起動引数を書く。実装した Claude が、見た目を変えた画面・状態をここに足し、
/// 判断の仕分けの Claude が、見える仮決めごとにここから 1 つ選ぶ。撮った画像は public の最終 PR に載るので、デモのデータの画面だけを書く
public struct ScreenshotScenesFile: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// 画面の数の上限
    public static let maximumScenes = 100
    /// 1 画面の起動引数の数の上限
    public static let maximumArguments = 30
    /// 起動引数 1 つ・説明の長さの上限（Unicode のコードポイントの数）
    public static let maximumTextLength = 300

    public struct Scene: Codable, Equatable, Sendable {
        /// 画面の名前（英小文字・数字・ハイフン。40 文字まで）。状態リポジトリのファイル名にも使う
        public var id: String
        /// 何の画面・状態か（人と Claude が読む）
        public var title: String
        /// その画面をデモのデータで開く起動引数（`simctl launch` でアプリに渡す。シェルは通さない）
        public var arguments: [String]

        public init(id: String, title: String, arguments: [String]) {
            self.id = id
            self.title = title
            self.arguments = arguments
        }
    }

    public var v: Int
    public var scenes: [Scene]

    public init(scenes: [Scene]) {
        v = Self.formatVersion
        self.scenes = scenes
    }

    public func scene(_ id: String) -> Scene? {
        scenes.first { $0.id == id }
    }

    /// 決まりに合わないところ。1 つでもあれば一覧を使わない
    public var problems: [String] {
        var problems: [String] = []
        if v != Self.formatVersion { problems.append("v は \(Self.formatVersion)") }
        if scenes.isEmpty || scenes.count > Self.maximumScenes { problems.append("scenes は 1〜\(Self.maximumScenes) 件") }
        let ids = scenes.map(\.id)
        if let bad = ids.first(where: { !Self.isSceneID($0) }) { problems.append("scene の id「\(bad)」は英小文字・数字・ハイフンで 40 文字まで") }
        if Set(ids).count != ids.count { problems.append("scene の id が重なっている") }
        for scene in scenes {
            if !Self.isText(scene.title) { problems.append("\(scene.id): title は空でなく、\(Self.maximumTextLength) 文字まで・制御文字なし") }
            if scene.arguments.count > Self.maximumArguments || !scene.arguments.allSatisfy(Self.isText) {
                problems.append("\(scene.id): arguments は \(Self.maximumArguments) 個まで、空でなく \(Self.maximumTextLength) 文字まで・制御文字なし")
            }
        }
        return problems
    }

    /// 画面の名前の形（英小文字・数字・ハイフン。先頭は英小文字か数字）
    public static func isSceneID(_ text: String) -> Bool {
        text.wholeMatch(of: #/[a-z0-9][a-z0-9-]{0,39}/#) != nil
    }

    private static func isText(_ text: String) -> Bool {
        (1...maximumTextLength).contains(text.unicodeScalars.count)
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
