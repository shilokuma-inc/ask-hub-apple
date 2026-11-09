import AskHubProtocol
import Foundation

/// Claude がタスクの区切りで返す報告（`docs/renewal/flows.md` の「Claude にビルドとテストを頼ませる」）
public struct TaskReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// 実装し終え、手元の検証が通った
        case done
        /// ビルドかテストを流してほしい（`buildKind`）。ワーカーが流し、結果を付けて同じ会話を再開する
        case needsBuild
        /// 人が決めないと進められない（`question`）。ワーカーが質問をクライアントに出す
        case needsQuestion
        /// 自分では解決できない理由で進められない（理由は `summary`）
        case blocked
    }

    /// 流してほしいビルドとテスト。値は `AskHubBuild` の `BuildKind` と同じ（つなぐときに `rawValue` で写す）
    public enum BuildKind: String, Codable, Sendable, CaseIterable {
        /// ビルドだけ
        case build
        /// 軽いテスト（UI テストを含まない）
        case testLight
        /// 全部のテスト（UI テストを含む）
        case testFull

        /// `other` の確かめを含むか（全部のテストは軽いテストを、テストはビルドを含む）
        public func covers(_ other: BuildKind) -> Bool { rank >= other.rank }

        private var rank: Int {
            switch self {
            case .build: 0
            case .testLight: 1
            case .testFull: 2
            }
        }
    }

    /// 仮決め（人に聞かずに Claude が決めたこと）。見える・内部の区分は、読むだけのレビュー役の Claude が決める
    public struct Decision: Codable, Equatable, Sendable {
        public var what: String
        public var why: String
        /// 選ばなかった案
        public var alternatives: [String]

        public init(what: String, why: String, alternatives: [String] = []) {
            self.what = what
            self.why = why
            self.alternatives = alternatives
        }
    }

    /// 人に聞きたいこと。形は質問づくりの質問と同じ（選択肢は 2〜4 個）
    public struct Question: Codable, Equatable, Sendable {
        public var title: String
        public var why: String
        public var options: [QuestionsFile.Option]
        /// 推奨の選択肢の label
        public var recommended: String
        /// 推奨の理由
        public var reason: String

        public init(title: String, why: String, options: [QuestionsFile.Option], recommended: String, reason: String) {
            self.title = title
            self.why = why
            self.options = options
            self.recommended = recommended
            self.reason = reason
        }
    }

    public var outcome: Outcome
    /// `needsBuild` のときだけ
    public var buildKind: BuildKind?
    public var summary: String
    public var decisions: [Decision]
    /// 見つけた知見。司令塔が知見を足す PR にする（人がマージしたものだけを取り込む）
    public var learnings: [String]
    /// `needsQuestion` のときだけ
    public var question: Question?

    public init(
        outcome: Outcome,
        buildKind: BuildKind? = nil,
        summary: String,
        decisions: [Decision] = [],
        learnings: [String] = [],
        question: Question? = nil
    ) {
        self.outcome = outcome
        self.buildKind = buildKind
        self.summary = summary
        self.decisions = decisions
        self.learnings = learnings
        self.question = question
    }

    /// 返してもらう形（`--json-schema`）。欄どうしの決まりは `problems(failing:)` で確かめる
    public static let outputSchema = OutputSchema.object([
        "outcome": OutputSchema.oneOf(
            Outcome.allCases.map(\.rawValue),
            "done（実装し終え、検証が通った）・needsBuild（ビルドかテストを流してほしい）・needsQuestion（人が決めないと進められない）・blocked（自分では解決できない理由で進められない）"
        ),
        "buildKind": OutputSchema.nullable(OutputSchema.oneOf(
            BuildKind.allCases.map(\.rawValue),
            "needsBuild のときだけ。build（ビルドだけ）・testLight（軽いテスト。UI テストを含まない）・testFull（UI テストを含む全部のテスト）"
        )),
        "summary": OutputSchema.string("done は何をしたか、needsBuild は何を確かめたいか、needsQuestion は何を聞きたいか、blocked はなぜ進められないか"),
        "decisions": OutputSchema.array(of: OutputSchema.object([
            "what": OutputSchema.string("何を決めたか"),
            "why": OutputSchema.string("なぜそう決めたか"),
            "alternatives": OutputSchema.array(of: OutputSchema.string("選ばなかった案"), "選ばなかった案。無ければ空")
        ]), "人に聞かずに決めたこと（仮決め）。無ければ空"),
        "learnings": OutputSchema.array(
            of: OutputSchema.string("知見"),
            "次に同じリポジトリで作業する人や Claude に役立つ知見（ハマりどころ・API の癖など）。無ければ空"
        ),
        "question": OutputSchema.nullable(OutputSchema.object([
            "title": OutputSchema.string("質問の題"),
            "why": OutputSchema.string("なぜ人が決める必要があるか"),
            "options": OutputSchema.array(of: OutputSchema.option, "選択肢（2〜4 個）"),
            "recommended": OutputSchema.string("推奨の選択肢の label"),
            "reason": OutputSchema.string("推奨の理由")
        ]))
    ], required: ["outcome", "summary", "decisions", "learnings"])

    /// 決まりに合わない点。空なら使える。`failing` は、この会話で落ちたまま、まだ通っていない検証（通っていれば nil）
    public func problems(failing: BuildKind?) -> [String] {
        var problems: [String] = []
        if summary.isBlank { problems.append("summary が空") }
        if outcome == .needsBuild, buildKind == nil { problems.append("outcome が needsBuild なのに、buildKind が無い") }
        if outcome != .needsBuild, buildKind != nil { problems.append("buildKind は needsBuild のときだけ書く（ほかのときは null）") }
        if outcome == .done, let failing {
            problems.append(
                "落ちた \(failing.rawValue) がまだ通っていないのに done にしている。直して needsBuild で \(failing.rawValue) 以上を流して確かめるか、進められなければ blocked にする"
            )
        }
        return problems + questionProblems + listProblems
    }

    private var questionProblems: [String] {
        switch (outcome, question) {
        case (.needsQuestion, nil): ["outcome が needsQuestion なのに、question が無い"]
        case let (.needsQuestion, question?): question.problems
        case (_, .some): ["question は needsQuestion のときだけ書く（ほかのときは null）"]
        case (_, nil): []
        }
    }

    private var listProblems: [String] {
        var problems: [String] = []
        if decisions.contains(where: { $0.what.isBlank || $0.why.isBlank }) { problems.append("decisions の what・why が空") }
        if decisions.contains(where: { $0.alternatives.contains(where: \.isBlank) }) { problems.append("decisions の alternatives に空の行がある") }
        if learnings.contains(where: \.isBlank) { problems.append("learnings に空の行がある") }
        return problems
    }
}

extension TaskReport.Question {
    var problems: [String] {
        var problems: [String] = []
        if title.isBlank || why.isBlank || reason.isBlank { problems.append("question の title・why・reason が空") }
        if let count = optionCountProblem(id: "question", count: options.count) { problems.append(count) }
        let labels = options.map(\.label)
        if labels.contains(where: \.isBlank) || Set(labels).count != labels.count { problems.append("question: 選択肢の label が空か重なっている") }
        if !labels.contains(recommended) { problems.append("question: 推奨（recommended）が選択肢の label に無い") }
        return problems
    }
}

extension String {
    /// 空か、空白と改行だけ
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
