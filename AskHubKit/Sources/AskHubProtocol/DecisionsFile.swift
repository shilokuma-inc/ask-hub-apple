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

    /// 画面の変化（状態リポジトリの中のパス。epic の `screenshots/` に置く）
    public struct Screenshots: Codable, Equatable, Sendable {
        public var before: String?
        public var after: String?

        public init(before: String? = nil, after: String? = nil) {
            self.before = before
            self.after = after
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
        /// どのタスクの仮決めか（ゴールのタスクの id）
        public var task: String
        /// 仮決めを含む子 PR。まだ PR が無ければ nil
        public var pullRequest: Int?
        /// 見えるか。仕分ける前は nil
        public var visible: Bool?
        public var what: String
        /// なぜ（ゴールのどの項目から来たか）
        public var why: String
        public var alternatives: [String]
        /// 見える仮決めの Before / After。撮る前は nil
        public var screenshots: Screenshots?
        /// 人の答え。見える仮決めだけが持つ
        public var answer: Answer?

        public init(
            id: String,
            task: String,
            pullRequest: Int? = nil,
            visible: Bool? = nil,
            what: String,
            why: String,
            alternatives: [String] = [],
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
            self.screenshots = screenshots
            self.answer = answer
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public var violations: [String] {
        var violations = LocalIDs.problems(items.map(\.id), dependencies: [:])
        for item in items {
            violations += problems(of: item)
        }
        return violations
    }

    private func problems(of item: Item) -> [String] {
        let name = item.id
        var problems: [String] = []
        if !LocalIDs.isValid(item.task) { problems.append("\(name): task の形が違う") }
        if let pullRequest = item.pullRequest, pullRequest < 1 { problems.append("\(name): pullRequest は 1 以上") }
        if item.what.isEmpty || item.why.isEmpty { problems.append("\(name): what・why が空") }
        if item.alternatives.contains(where: \.isEmpty) { problems.append("\(name): 空のほかの案がある") }
        // スクショと人の答えは、見えると仕分けた仮決めだけが持つ（内部の細部は畳んで並べるだけ）
        if item.visible != true, item.screenshots != nil || item.answer != nil {
            problems.append("\(name): 見える仮決めでないのに、スクショか答えがある")
        }
        if let screenshots = item.screenshots {
            for path in [screenshots.before, screenshots.after].compactMap({ $0 }) where !Self.isScreenshotPath(path) {
                problems.append("\(name): スクショのパスの形が違う")
            }
        }
        return problems
    }

    /// 状態リポジトリの中の epic の `screenshots/` の下の PNG（`..` や絶対パスを含まない）
    static func isScreenshotPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("repos/") && path.hasSuffix(".png") && parts.contains("screenshots")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
