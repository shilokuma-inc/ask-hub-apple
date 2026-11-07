import Foundation

/// 子 PR のレビュー（`reviewTask`）の判定。司令塔は、これを読んで次のジョブを決める
public enum ReviewVerdict: String, Codable, Sendable, CaseIterable {
    /// チェックが通り、レビュー役の必須の指摘も無く、見た head でマージした（子 PR）
    case merged
    /// 最終 PR のチェックとレビューが通った。マージはマージの規則と人の承認で決める（最終 PR）
    case ready
    /// CI が落ちた（揺らぎの流し直しの後も）。`findings` に落ちたチェックとログの抜粋
    case fixCI
    /// レビュー役が必須の指摘をした。`findings` に指摘
    case fixReview
}

/// 実装と直し（`implementTask`・`fixTask`）で Claude が報告したこと。司令塔が `decisions.json`・知見を足す PR・質問に写す
public struct TaskOutputReport: Codable, Equatable, Sendable {
    /// 仮決め（見える・内部の区分は、レビュー役が決めて `decisions.json` に書く）
    public struct Decision: Codable, Equatable, Sendable {
        public var what: String
        public var why: String
        public var alternatives: [String]

        public init(what: String, why: String, alternatives: [String] = []) {
            self.what = what
            self.why = why
            self.alternatives = alternatives
        }
    }

    /// 人に聞きたいこと（実装の途中で、人が決めないと進められないとき）。形は質問づくりの質問と同じ
    public struct Question: Codable, Equatable, Sendable {
        public var title: String
        public var why: String
        public var options: [QuestionsFile.Option]
        public var recommended: String
        public var reason: String

        public init(title: String, why: String, options: [QuestionsFile.Option], recommended: String, reason: String) {
            self.title = title
            self.why = why
            self.options = options
            self.recommended = recommended
            self.reason = reason
        }
    }

    public var summary: String
    public var decisions: [Decision]
    public var learnings: [String]
    public var question: Question?

    public init(summary: String, decisions: [Decision] = [], learnings: [String] = [], question: Question? = nil) {
        self.summary = summary
        self.decisions = decisions
        self.learnings = learnings
        self.question = question
    }

    var problems: [String] {
        var problems: [String] = []
        if summary.isEmpty { problems.append("report.summary が空") }
        if decisions.contains(where: { $0.what.isEmpty || $0.why.isEmpty || $0.alternatives.contains(where: \.isEmpty) }) {
            problems.append("report.decisions の what・why・alternatives が空")
        }
        if learnings.contains(where: \.isEmpty) { problems.append("report.learnings に空のものがある") }
        if let question {
            let labels = question.options.map(\.label)
            if question.title.isEmpty || question.why.isEmpty || question.reason.isEmpty {
                problems.append("report.question の title・why・reason が空")
            }
            if !(2...4).contains(labels.count) || Set(labels).count != labels.count || labels.contains(where: \.isEmpty) {
                problems.append("report.question の選択肢は、空でない別々のものを 2〜4 個")
            }
            if !labels.contains(question.recommended) { problems.append("report.question の推奨が選択肢に無い") }
        }
        return problems
    }
}

/// 最終 PR のレビュー（`reviewFinalPullRequest`）が見つけた、手動のマージの条件に当たるもの（`docs/renewal/flows.md` の「マージの規則」）
public struct MergeRisk: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// レビュー役（または CodeRabbit）がセキュリティのリスクを指摘した
        case security
        /// 自動の修正がテストを消した・skip にした・Lint を緩めた
        case weakenedTests
        /// データの削除・移行を含む
        case dataMigration
        /// 注意の要るパス（`.github/`・ビルドのスクリプト・依存の追加・entitlements・署名の設定・トークンや Keychain のコードなど）に差分がある
        case sensitivePaths
    }

    public var kind: Kind
    public var reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

extension AttemptFile.Outputs {
    /// `findings` の長さの上限（Unicode のコードポイントの数。JSON Schema の maxLength と同じ数え方）。超えた分はワーカーが省いてから書く
    public static let maximumFindingsLength = 20_000
}
