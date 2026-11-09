import Foundation

/// 人が決めていない判断（ループの仮決め）の一覧（`repos/<owner>/<repo>/epics/<epic>/decisions.json`）。司令塔だけが書く。
///
/// 実装した Claude が報告した仮決めを、タスクごとに足す。見える（挙動・仕様・見た目に関わる）か内部の細部かは、
/// 読むだけのレビュー役の Claude と決まった信号で決める（`docs/renewal/flows.md` の「人が決めていない判断の確認」）
public struct DecisionsFile: StateFile {
    public static let formatVersion = 1

    /// 人の答え（判断のカードの「OK」「別案にする」「直してほしい」）
    public enum Choice: String, Codable, Sendable, CaseIterable {
        case ok
        case alternative
        case fix
    }

    /// 画面の変化（撮影のジョブ `captureScreenshots` が撮ったもの。`docs/renewal/flows.md` の「スクショ」）
    public struct Screenshots: Codable, Equatable, Sendable {
        /// GitHub に上げた画像の URL の先頭（最終 PR の本文に載せる。ほかの URL は載せない）
        public static let attachmentURLPrefix = "https://github.com/user-attachments/assets/"
        /// 撮れなかったわけの長さの上限（Unicode のコードポイントの数）
        public static let maximumNoteLength = 500

        /// Before（base との分岐点）の画像。状態リポジトリの中のパス（epic の `screenshots/` の下）。撮れなかったら nil
        public var before: String?
        /// After（作業ブランチの先頭）の画像。撮れなかったら nil
        public var after: String?
        /// GitHub に上げた Before の画像の URL。上げられなかったら nil
        public var beforeURL: String?
        public var afterURL: String?
        /// After を撮ったコミット（作業ブランチの先頭）
        public var head: String?
        /// 撮れなかったわけ・Before が無いわけ（人が読む）
        public var note: String?

        public init(
            before: String? = nil,
            after: String? = nil,
            beforeURL: String? = nil,
            afterURL: String? = nil,
            head: String? = nil,
            note: String? = nil
        ) {
            self.before = before
            self.after = after
            self.beforeURL = beforeURL
            self.afterURL = afterURL
            self.head = head
            self.note = note
        }

        /// 形の決まりに合わないところ
        public var problems: [String] {
            var problems: [String] = []
            if [before, after].contains(where: { $0.map { !DecisionsFile.isScreenshotPath($0) } ?? false }) {
                problems.append("スクショのパスの形が違う")
            }
            if [beforeURL, afterURL].contains(where: { $0.map { !Self.isAttachmentURL($0) } ?? false }) {
                problems.append("スクショの URL が GitHub の添付（\(Self.attachmentURLPrefix)…）でない")
            }
            if let head, !AttemptFile.isCommitSHA(head) { problems.append("スクショの head の形が違う") }
            if let note, note.isEmpty || note.unicodeScalars.count > Self.maximumNoteLength {
                problems.append("スクショの note は空でなく、\(Self.maximumNoteLength) 文字まで")
            }
            return problems
        }

        /// GitHub に上げた画像の URL（`https://github.com/user-attachments/assets/<id>`。id は英数字とハイフン）
        public static func isAttachmentURL(_ text: String) -> Bool {
            guard text.hasPrefix(attachmentURLPrefix) else { return false }
            return text.dropFirst(attachmentURLPrefix.count).wholeMatch(of: #/[A-Za-z0-9-]{1,100}/#) != nil
        }
    }

    public struct Answer: Codable, Equatable, Sendable {
        public var choice: Choice
        /// 別案・直してほしいときの補足（OK なら空）
        public var note: String
        public var intent: IntentReference
        public var at: Timestamp

        public init(choice: Choice, note: String = "", intent: IntentReference, at: Timestamp) {
            self.choice = choice
            self.note = note
            self.intent = intent
            self.at = at
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        /// epic の中の id（`d1` など）
        public var id: String
        /// どのタスクの仮決めか（ゴールのタスクの id）。最終 PR の直しの仮決めはタスクに結びつかないので nil
        public var task: String?
        /// 仮決めを含む PR（タスクの仮決めは子 PR、最終 PR の直しの仮決めは最終 PR）。まだ PR が無ければ nil
        public var pullRequest: Int?
        /// 見えるか。仕分ける前は nil
        public var visible: Bool?
        public var what: String
        /// なぜ（ゴールのどの項目から来たか）
        public var why: String
        public var alternatives: [String]
        /// 撮る画面（リポジトリの撮れる画面の一覧の id）。判断の仕分けの Claude が見える仮決めごとに選ぶ。合う画面が無ければ nil
        public var scene: String?
        /// 見える仮決めの Before / After。撮る前は nil
        public var screenshots: Screenshots?
        /// 人の答え。見える仮決めだけが持つ
        public var answer: Answer?

        public init(
            id: String,
            task: String?,
            pullRequest: Int? = nil,
            visible: Bool? = nil,
            what: String,
            why: String,
            alternatives: [String] = [],
            scene: String? = nil,
            screenshots: Screenshots? = nil,
            answer: Answer? = nil
        ) {
            self.id = id
            self.task = task
            self.pullRequest = pullRequest
            self.visible = visible
            self.what = what
            self.why = why
            self.alternatives = alternatives
            self.scene = scene
            self.screenshots = screenshots
            self.answer = answer
        }
    }

    /// epic 全体で見た目が変わった画面（仮決めに結びつかない画面の変化）。最終 PR と AskHub に「画面の変化」として Before / After を出す
    public struct ScreenChange: Codable, Equatable, Sendable {
        /// 何の画面か（撮れる画面の一覧の `title`）の長さの上限
        public static let maximumTitleLength = ScreenshotScenesFile.maximumTextLength

        /// 撮れる画面の一覧の id
        public var scene: String
        /// 何の画面か（撮ったときの一覧の `title`）。撮る前は nil
        public var title: String?
        /// 撮る前は nil
        public var screenshots: Screenshots?

        public init(scene: String, title: String? = nil, screenshots: Screenshots? = nil) {
            self.scene = scene
            self.title = title
            self.screenshots = screenshots
        }

        var problems: [String] {
            var problems: [String] = []
            if !ScreenshotScenesFile.isSceneID(scene) { problems.append("scene の形が違う") }
            if let title, title.isEmpty || title.unicodeScalars.count > Self.maximumTitleLength {
                problems.append("title は空でなく、\(Self.maximumTitleLength) 文字まで")
            }
            return problems + (screenshots?.problems ?? [])
        }
    }

    public var items: [Item]
    /// 画面の変化。判断の仕分けで選ぶ前（撮影の設定が無いリポジトリを含む）は nil、選んで無ければ空
    public var screens: [ScreenChange]?

    public init(items: [Item] = [], screens: [ScreenChange]? = nil) {
        self.items = items
        self.screens = screens
    }

    public var violations: [String] {
        var violations = LocalIDs.problems(items.map(\.id), dependencies: [:])
        for item in items {
            violations += problems(of: item)
        }
        let screens = screens ?? []
        if Set(screens.map(\.scene)).count != screens.count { violations.append("screens の scene が重なっている") }
        violations += screens.flatMap { screen in screen.problems.map { "screens.\(screen.scene): \($0)" } }
        return violations
    }

    private func problems(of item: Item) -> [String] {
        let name = item.id
        var problems: [String] = []
        if let task = item.task, !LocalIDs.isValid(task) { problems.append("\(name): task の形が違う") }
        if let pullRequest = item.pullRequest, pullRequest < 1 { problems.append("\(name): pullRequest は 1 以上") }
        if item.what.isEmpty || item.why.isEmpty { problems.append("\(name): what・why が空") }
        if item.alternatives.contains(where: \.isEmpty) { problems.append("\(name): 空のほかの案がある") }
        // 撮る画面・スクショ・人の答えは、見えると仕分けた仮決めだけが持つ（内部の細部は畳んで並べるだけ）
        if item.visible != true, item.scene != nil || item.screenshots != nil || item.answer != nil {
            problems.append("\(name): 見える仮決めでないのに、撮る画面・スクショ・答えのどれかがある")
        }
        if let scene = item.scene, !ScreenshotScenesFile.isSceneID(scene) { problems.append("\(name): scene の形が違う") }
        problems += (item.screenshots?.problems ?? []).map { "\(name): \($0)" }
        return problems
    }

    /// 状態リポジトリの中の epic の `screenshots/` の下の PNG（`..` や絶対パスを含まない）
    public static func isScreenshotPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("repos/") && path.hasSuffix(".png") && parts.contains("screenshots")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
