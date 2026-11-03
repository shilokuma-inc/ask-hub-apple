import AskHubEpics
import AskHubProtocol
import Foundation

/// 質問の選択肢の数。まとめて判断するのカードは、斜めの 4 方向まで（`docs/renewal/flows.md` の「質問の形」）
let optionCountRange = 2...4

/// 依頼から最初の質問を作る（`makeQuestions`）
public struct MakeQuestionsJob: ClaudeJob {
    public struct Output: Codable, Equatable, Sendable {
        /// 依頼の要約（何を作るか・なぜ）。Discussion に書く
        public var summary: String
        public var questions: [QuestionDraft]

        public init(summary: String, questions: [QuestionDraft]) {
            self.summary = summary
            self.questions = questions
        }
    }

    public static let kind = JobKind.makeQuestions
    public static let timeout = Duration.seconds(15 * 60)
    public static let outputSchema = OutputSchema.object([
        "summary": OutputSchema.string("依頼の要約（何を作るか・なぜ）を 3〜5 文で"),
        "questions": OutputSchema.array(of: OutputSchema.questionDraft, "人が決めるべきことの質問。無ければ空")
    ])
    /// 1 回の質問づくりで出す質問の上限（多すぎる依頼は、着手前の確認で分け方を考える）
    public static let maximumQuestions = 12

    public var title: String
    public var body: String
    /// 添付の名前（作業フォルダの `attachments/` に置く）
    public var attachments: [String]

    public init(title: String, body: String, attachments: [String] = []) {
        self.title = title
        self.body = body
        self.attachments = attachments
    }

    public var prompt: String {
        """
        次の依頼について、実装を始める前に人が決めるべきことを質問にしてください。

        ## 依頼
        題: \(title)
        <request>
        \(body)
        </request>
        添付: \(attachments.isEmpty ? "なし" : attachments.joined(separator: "、") + "（作業フォルダの attachments/ にある。必要なら読む）")

        ## 質問の決まり
        - 人が決めないと実装できないこと、決め方で作るものが大きく変わることだけを質問にする。リポジトリを読めば分かること・慣習で決まることは質問にしない
        - 質問ごとに、なぜ決める必要があるか（why）、選択肢ごとに何が変わるか（options の effect）、推奨（recommended。options の label のどれか）とその理由（reason）を書く
        - 選択肢は 2〜4 個。label は短く（30 文字程度まで）、重ならないようにする。選択肢に無い答えは、人が自由記述で書ける
        - ほかの質問の答えを前提にする質問は、dependsOn にその質問の id を書く（循環させない）。前提が無ければ空にする
        - 間違えると取り返しのつかない質問（セキュリティ・個人のデータ・取り消せない変更・お金がかかる）にだけ、caution（kind と reason）を付ける
        - id は q1・q2・… の順に付ける
        - 質問は多くても \(Self.maximumQuestions) 個まで。決めることが無ければ空の一覧でよい
        - summary に、依頼の要約（何を作るか・なぜ）を 3〜5 文で書く
        """
    }

    public func problems(in output: Output) -> [String] {
        var problems: [String] = []
        if output.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("summary が空") }
        if output.questions.count > Self.maximumQuestions { problems.append("質問は \(Self.maximumQuestions) 個まで") }
        problems += output.questions.compactMap { optionCountProblem(id: $0.id, count: $0.options.count) }
        do throws(QuestionFlow.ResultError) {
            _ = try QuestionFlow.start(output.questions)
        } catch let .invalid(found) {
            problems += found
        } catch {
            problems.append("質問の一覧を作れない（\(error)）")
        }
        return problems
    }
}

/// 人が説明を求めた質問に、説明を書く（`explain`）
public struct ExplainJob: ClaudeJob {
    public struct Output: Codable, Equatable, Sendable {
        public var text: String
        /// 質問の立て方が悪いと判断したときだけ、書き直しの案
        public var rewrite: QuestionRewrite?

        public init(text: String, rewrite: QuestionRewrite? = nil) {
            self.text = text
            self.rewrite = rewrite
        }
    }

    public static let kind = JobKind.explain
    public static let timeout = Duration.seconds(10 * 60)
    public static let outputSchema = OutputSchema.object([
        "text": OutputSchema.string("人の問いに答える説明"),
        "rewrite": OutputSchema.nullable(OutputSchema.questionRewrite)
    ], required: ["text"])

    /// 説明を求めた時点の質問の一覧
    public var questions: QuestionsFile
    public var question: String
    public var asked: IntentReference

    public init(questions: QuestionsFile, question: String, asked: IntentReference) {
        self.questions = questions
        self.question = question
        self.asked = asked
    }

    public var prompt: String {
        let target = questions.questions.first { $0.id == question }
        let explanations = target?.explanations ?? []
        let earlier = explanations.dropLast().map { "- 問い: \($0.note)\n  説明: \($0.text ?? "")" }
        return """
        人が次の質問について説明を求めました。リポジトリを読み、人が選べるように説明してください。

        ## 質問
        \(target.map(PromptText.question) ?? "（見つからない）")

        ## これまでの説明
        \(earlier.isEmpty ? "なし" : earlier.joined(separator: "\n"))

        ## 人の問い
        <question>
        \(explanations.last?.note.isEmpty == false ? explanations.last?.note ?? "" : "（詳しい説明がほしい）")
        </question>

        ## 決まり
        - text に説明を書く。人の問いに答え、専門用語は言い換える。長くても 15 文程度
        - 質問の立て方が悪い（選択肢が足りない・紛らわしい・前提が違う）と判断したときだけ、rewrite に書き直しの案を出す。案は中身を丸ごと置き換えるので、変えない欄もすべて書く。change に書き直した理由を書く。書き直さないなら rewrite は null
        - 選択肢は 2〜4 個
        """
    }

    public func problems(in output: Output) -> [String] {
        var problems = output.rewrite.flatMap { optionCountProblem(id: question, count: $0.options.count) }.map { [$0] } ?? []
        do throws(QuestionFlow.ResultError) {
            _ = try QuestionFlow.explain(question, asked: asked, text: output.text, rewrite: output.rewrite, in: questions)
        } catch let .invalid(found) {
            problems += found
        } catch {
            // 頼んだ後に状態が変わった（stale）のは Claude の誤りではないので、直させない。書くときに捨てる
        }
        return problems
    }
}

/// 依存先が決まった質問を見直す（`reviseQuestion`）
public struct ReviseQuestionJob: ClaudeJob {
    public enum Decision: String, Codable, Sendable, CaseIterable {
        case keep
        case rewrite
        case drop
    }

    public struct Output: Codable, Equatable, Sendable {
        public var decision: Decision
        public var reason: String
        public var rewrite: QuestionRewrite?

        public init(decision: Decision, reason: String, rewrite: QuestionRewrite? = nil) {
            self.decision = decision
            self.reason = reason
            self.rewrite = rewrite
        }
    }

    public static let kind = JobKind.reviseQuestion
    public static let timeout = Duration.seconds(10 * 60)
    public static let outputSchema = OutputSchema.object([
        "decision": OutputSchema.oneOf(Decision.allCases.map(\.rawValue), "keep（そのまま）・rewrite（書き直す）・drop（要らなくなった）"),
        "reason": OutputSchema.string("そう判断した理由"),
        "rewrite": OutputSchema.nullable(OutputSchema.questionRewrite)
    ], required: ["decision", "reason"])

    /// 見直しを頼んだ時点の質問の一覧と、頼んだときの版と回答
    public var questions: QuestionsFile
    public var question: String
    public var basis: RevisionBasis

    public init(questions: QuestionsFile, question: String, basis: RevisionBasis) {
        self.questions = questions
        self.question = question
        self.basis = basis
    }

    public var prompt: String {
        let target = questions.questions.first { $0.id == question }
        let dependencies = (target?.dependsOn ?? []).compactMap { id in questions.questions.first { $0.id == id } }
        return """
        次の質問は、ほかの質問の回答を前提にしています。前提の質問が決まったので、この質問を見直してください。

        ## 見直す質問
        \(target.map(PromptText.question) ?? "（見つからない）")

        ## 前提の質問と決まったこと
        \(dependencies.map(PromptText.decision).joined(separator: "\n\n"))

        ## 決まり
        - そのままでよければ decision を keep にする
        - 決まったことを受けて、選択肢や問い方を変えるべきなら rewrite にし、rewrite に書き直しの案を出す。案は中身を丸ごと置き換えるので、変えない欄もすべて書く。change に書き直した理由を書く
        - 決まったことによって、この質問そのものが要らなくなったら drop にする
        - reason に、そう判断した理由を書く
        - 選択肢は 2〜4 個
        """
    }

    public func outcome(of output: Output) -> QuestionFlow.RevisionOutcome {
        switch output.decision {
        case .keep: .keep
        case .drop: .drop(reason: output.reason)
        case .rewrite: output.rewrite.map(QuestionFlow.RevisionOutcome.rewrite) ?? .keep
        }
    }

    public func problems(in output: Output) -> [String] {
        var problems: [String] = []
        if output.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("reason が空") }
        if output.decision == .rewrite && output.rewrite == nil { problems.append("decision が rewrite なのに、rewrite が無い") }
        if let rewrite = output.rewrite, output.decision == .rewrite {
            problems += optionCountProblem(id: question, count: rewrite.options.count).map { [$0] } ?? []
        }
        do throws(QuestionFlow.ResultError) {
            _ = try QuestionFlow.revise(question, basis: basis, outcome: outcome(of: output), in: questions)
        } catch let .invalid(found) {
            problems += found
        } catch {
            // 頼んだ後に状態が変わった（stale）のは Claude の誤りではないので、直させない。書くときに捨てる
        }
        return problems
    }
}

func optionCountProblem(id: String, count: Int) -> String? {
    optionCountRange.contains(count) ? nil : "\(id): 選択肢は \(optionCountRange.lowerBound)〜\(optionCountRange.upperBound) 個"
}

/// 依頼の文に質問を書き出す
enum PromptText {
    static func question(_ question: QuestionsFile.Question) -> String {
        var lines = [
            "id: \(question.id)",
            "題: \(question.title)",
            "なぜ決めるか: \(question.why)",
            "選択肢:"
        ]
        lines += question.options.map { "- \($0.label): \($0.effect)" }
        lines += ["推奨: \(question.recommended)（\(question.reason)）"]
        if let caution = question.caution { lines.append("慎重に決めてほしい理由: \(caution.kind.rawValue)（\(caution.reason)）") }
        return lines.joined(separator: "\n")
    }

    static func goal(_ goal: GoalFile) -> String {
        var lines = ["要約: \(goal.summary)", "決まったこと:"]
        lines += goal.decided.map { "- \($0.question): \($0.text)" }
        lines += ["やらないこと:"] + goal.outOfScope.map { "- \($0)" }
        lines += ["完了の条件:"] + goal.doneWhen.map { "- \($0)" }
        lines += ["タスク:"] + goal.tasks.map { task in
            let detail = task.detail.map { "（\($0)）" } ?? ""
            let premise = task.dependsOn.isEmpty ? "" : " 前提: \(task.dependsOn.joined(separator: "・"))"
            return "- \(task.id): \(task.title)\(detail)\(premise)"
        }
        lines += ["人がする作業:"] + goal.humanTasks.map { task in
            "- \(task.id): \(task.title)（\(task.why)）手順: \(task.steps.joined(separator: " → "))"
        }
        return lines.joined(separator: "\n")
    }

    static func decision(_ question: QuestionsFile.Question) -> String {
        let decided: String
        switch (question.state, question.answer) {
        case let (.answered, answer?):
            let note = answer.note.isEmpty ? "" : "\n補足: \(answer.note)"
            decided = "回答: \(answer.choice ?? "（自由記述）")\(note)"
        case (.dropped, _):
            decided = "見直しで要らなくなった（\(question.revision?.reason ?? "")）"
        default:
            decided = "（まだ決まっていない）"
        }
        return "\(question.id): \(question.title)\n\(decided)"
    }
}
