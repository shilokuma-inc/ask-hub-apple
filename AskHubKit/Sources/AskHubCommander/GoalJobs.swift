import AskHubEpics
import AskHubProtocol
import Foundation

/// 回答一式を確かめ、ゴールの案・追加の質問・分け方の案のどれかを出す（`checkReadiness`）
public struct CheckReadinessJob: ClaudeJob {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// 進めてよい。ゴールの案を出す
        case ready
        /// 追加の質問が要る
        case moreQuestions
        /// 1 つの epic に収まらない（追加の質問を使い切って決めきれないときも、理由を書いてこれにする）
        case tooLarge
    }

    /// 分け方の案の 1 つ
    public struct Part: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String

        public init(title: String, summary: String) {
            self.title = title
            self.summary = summary
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public var verdict: Verdict
        public var reason: String
        public var goal: GoalDraft?
        public var questions: [QuestionDraft]?
        public var split: [Part]?

        public init(verdict: Verdict, reason: String, goal: GoalDraft? = nil, questions: [QuestionDraft]? = nil, split: [Part]? = nil) {
            self.verdict = verdict
            self.reason = reason
            self.goal = goal
            self.questions = questions
            self.split = split
        }
    }

    public static let kind = JobKind.checkReadiness
    public static let timeout = Duration.seconds(15 * 60)
    /// 質問を出せる最後の回（最初の質問づくりが 1。`round` が 4 になる前に、人に「大きすぎる・決めきれない」と出す）
    public static let lastQuestionRound = 3
    /// 「このまま 1 つで進める」と決めた後は、決めきれない点を人に聞けるよう、1 回だけ延ばす（ユーザーの決定）
    public static let lastQuestionRoundAfterProceeding = lastQuestionRound + 1
    public static let outputSchema = OutputSchema.object([
        "verdict": OutputSchema.oneOf(Verdict.allCases.map(\.rawValue), "ready（進めてよい）・moreQuestions（追加の質問が要る）・tooLarge（1 つの epic に収まらない）"),
        "reason": OutputSchema.string("そう判断した理由"),
        "goal": OutputSchema.nullable(OutputSchema.goalDraft),
        "questions": OutputSchema.nullable(OutputSchema.array(of: OutputSchema.questionDraft, "追加の質問")),
        "split": OutputSchema.nullable(OutputSchema.array(of: OutputSchema.object([
            "title": OutputSchema.string("分けた epic の題"),
            "summary": OutputSchema.string("分けた epic で作るもの")
        ]), "分け方の案（2 つ以上）"))
    ], required: ["verdict", "reason"])

    public var title: String
    public var body: String
    public var questions: QuestionsFile
    /// 添付を置いた場所（Claude が読んでよいフォルダの中のパス）
    public var attachments: [String]
    /// 追加の質問を出すときの回（今までの最も新しい回の次）
    public var nextRound: Int
    /// 人が分け方の判断で「このまま 1 つで進める」を選んだ後の確認。大きすぎるとは返させない（追加の質問は、回が残っていれば出せる）
    public var proceeding: Bool

    public init(title: String, body: String, questions: QuestionsFile, attachments: [String] = [], proceeding: Bool = false) {
        self.title = title
        self.body = body
        self.questions = questions
        self.attachments = attachments
        self.proceeding = proceeding
        // 最初の質問づくりは、質問が 1 つも無くても 1 回目と数える
        nextRound = (questions.questions.map(\.round).max() ?? 1) + 1
    }

    /// 追加の質問をもう出せるか
    public var canAskMore: Bool { nextRound <= (proceeding ? Self.lastQuestionRoundAfterProceeding : Self.lastQuestionRound) }

    public var prompt: String {
        let decisions = questions.questions.map(PromptText.decision)
        return """
        次の依頼と、人が決めたことの一式を確かめてください。問題が無ければ、実装のゴールを作ってください。

        ## 依頼
        題: \(title)
        <request>
        \(body)
        </request>
        添付: \(attachments.isEmpty ? "なし" : attachments.joined(separator: "、") + "（依頼に付いていたファイル。必要なら読む）")

        ## 人が決めたこと
        \(decisions.isEmpty ? "（質問は無かった）" : decisions.joined(separator: "\n\n"))

        ## 確かめること
        - 決めたことどうしに矛盾が無いか
        - 決めたことによって、新しく人が決めるべき点が出ていないか
        - 補足の自由記述に、質問の範囲を超えた要望が入っていないか
        - 必要な素材（画像など）がそろっているか
        - 1 つの epic（1 本の作業ブランチと最終 PR）に収まる規模か
        - AskHub だけではできない作業（App Store Connect の Web でしかできない設定など）が要るか

        ## 返し方
        - 問題が無ければ verdict を ready にし、goal を書く
          - summary: 作るものの要約
          - decided: 回答した質問をすべて、質問の id ごとに 1 つずつ（何に決まったかを text に書く）
          - outOfScope: やらないこと
          - doneWhen: 完了の条件（確かめられる形で）
          - tasks: 実装のタスク（id は t1・t2・…。1 つのタスクは 1 本の子 PR に収まる大きさ。前提のタスクと人がする作業の id を dependsOn に書く）
          - humanTasks: 人がする作業（id は h1・h2・…。手順は入れる値まで具体的に。リンクは https だけ）
            GitHub の Secrets に入れる値は handover を {"kind": "secret", "name": "英大文字の名前"} にし、値そのものは書かない
        \(rules)
        - reason に、そう判断した理由を書く
        """
    }

    /// 追加の質問と、大きすぎるときの返し方
    private var rules: String {
        switch (proceeding, canAskMore) {
        case (false, true): Self.askMoreRule + "\n" + Self.tooLargeRule
        case (false, false): Self.noMoreQuestionsRule + "\n" + Self.tooLargeRule
        case (true, true): Self.proceedingRule + "\n" + Self.askMoreRule
        case (true, false): Self.proceedingRule + "\n" + Self.provisionalRule
        }
    }

    private static let tooLargeRule = """
        - 1 つの epic に収まらなければ verdict を tooLarge にし、split に分け方の案（2 つ以上）を書く
        """
    private static let proceedingRule = """
        - 1 つの epic に収まらないと前に伝えたが、人はそれを承知で、このまま 1 つで進めると決めた。tooLarge は返さない
        """
    private static let provisionalRule = """
        - 追加の質問はもう出せない（このまま進めると決めた後に 1 回延ばした分も使い切った）。人が決めるべき点が残っていても verdict を ready にして
          ゴールを作る。決めきれない点は推奨の案で仮に決め、goal の summary の末尾に「仮に決めたこと:」として書く（人が開始の前にゴールを確かめて直せる）
        """

    private static let askMoreRule = """
        - 人が決めるべき点が残っていれば verdict を moreQuestions にし、questions に追加の質問を書く
          （id は今までと重ならないように。選択肢は 2〜4 個。決まりは最初の質問づくりと同じ）
        """
    private static let noMoreQuestionsRule = """
        - 追加の質問はもう出せない。人が決めるべき点が残っていて決めきれないときは、verdict を tooLarge にし、
          reason に何が決めきれないかを書く
        """

    public func problems(in output: Output) -> [String] {
        let reason = output.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["reason が空"] : []
        if proceeding && output.verdict == .tooLarge { return reason + ["人がこのまま 1 つで進めると決めたので、tooLarge は返せない"] }
        switch output.verdict {
        case .ready:
            guard let goal = output.goal else { return reason + ["verdict が ready なのに、goal が無い"] }
            return reason + goalProblems(goal, questions: questions)
        case .moreQuestions:
            return reason + questionProblems(output.questions)
        case .tooLarge:
            return reason + splitProblems(output.split ?? [])
        }
    }

    private func questionProblems(_ drafts: [QuestionDraft]?) -> [String] {
        guard canAskMore else { return ["追加の質問はもう出せない。" + (proceeding ? "ready にする" : "ready か tooLarge にする")] }
        guard let drafts, !drafts.isEmpty else { return ["verdict が moreQuestions なのに、questions が無い"] }
        var problems = drafts.compactMap { optionCountProblem(id: $0.id, count: $0.options.count) }
        if drafts.count > MakeQuestionsJob.maximumQuestions { problems.append("追加の質問は \(MakeQuestionsJob.maximumQuestions) 個まで") }
        do throws(QuestionFlow.ResultError) {
            _ = try QuestionFlow.append(drafts, round: nextRound, to: questions)
        } catch let .invalid(found) {
            problems += found
        } catch {
            problems.append("追加の質問を足せない（\(error)）")
        }
        return problems
    }

    /// 決めきれずに追加の質問を使い切ったときは、分け方の案が無くてもよい
    private func splitProblems(_ parts: [Part]) -> [String] {
        var problems: [String] = []
        if canAskMore && parts.count < 2 { problems.append("verdict が tooLarge なのに、split に 2 つ以上の案が無い") }
        if parts.contains(where: { $0.title.isEmpty || $0.summary.isEmpty }) { problems.append("split の title・summary が空") }
        return problems
    }
}

/// 人の指示でゴールを直す（`reviseGoal`）
public struct ReviseGoalJob: ClaudeJob {
    public struct Output: Codable, Equatable, Sendable {
        public var goal: GoalDraft
        /// 反映しなかった指示とその理由（決めたことを変える指示など）。人に出す
        public var notApplied: [String]

        public init(goal: GoalDraft, notApplied: [String] = []) {
            self.goal = goal
            self.notApplied = notApplied
        }
    }

    public static let kind = JobKind.reviseGoal
    public static let timeout = Duration.seconds(10 * 60)
    public static let outputSchema = OutputSchema.object([
        "goal": OutputSchema.goalDraft,
        "notApplied": OutputSchema.array(of: OutputSchema.string("反映しなかった指示と理由"), "反映しなかった指示。無ければ空")
    ])

    public var goal: GoalFile
    public var questions: QuestionsFile
    /// 人の指示
    public var instruction: String

    public init(goal: GoalFile, questions: QuestionsFile, instruction: String) {
        self.goal = goal
        self.questions = questions
        self.instruction = instruction
    }

    public var prompt: String {
        """
        次のゴールを、人の指示に沿って直してください。直したゴールを、丸ごと同じ形で返してください（変えない部分もすべて書く）。

        ## 今のゴール
        \(PromptText.goal(goal))

        ## 人が決めたこと
        \(questions.questions.map(PromptText.decision).joined(separator: "\n\n"))

        ## 人の指示
        <instruction>
        \(instruction)
        </instruction>

        ## 決まり
        - 人が決めたことを変える指示は、ゴールでは変えない（決めたことは、人が回答を変えて直す）。反映しなかった指示は、理由とあわせて notApplied に書く
        - decided は、今のゴールのものをそのまま書き写す（変えない）
        - タスクの id は t1・t2・…、人がする作業の id は h1・h2・…。リンクは https だけ。Secrets の値は書かない
        """
    }

    public func problems(in output: Output) -> [String] {
        var problems = goalProblems(output.goal, questions: questions)
        // 決まったことは回答から来ているので、ゴールの修正では変えない（変える指示は notApplied に書く）
        if output.goal.decided != goal.decided { problems.append("決まったこと（decided）は変えない。変える指示は notApplied に書く") }
        if output.notApplied.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            problems.append("notApplied に空の行がある")
        }
        return problems
    }
}

private func goalProblems(_ draft: GoalDraft, questions: QuestionsFile) -> [String] {
    do throws(QuestionFlow.ResultError) {
        _ = try GoalFlow.goal(from: draft, questions: questions, version: 1)
        return []
    } catch let .invalid(found) {
        return found
    } catch {
        return ["ゴールを作れない（\(error)）"]
    }
}
