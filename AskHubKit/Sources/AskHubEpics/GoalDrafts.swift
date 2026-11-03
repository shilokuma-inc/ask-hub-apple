import AskHubProtocol
import Foundation

/// 着手前の確認・ゴールの修正の Claude が返す、ゴールの案（`goal.json` から状態と版を除いたもの）
public struct GoalDraft: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String?
        /// ほかのタスクと、人がする作業の id
        public var dependsOn: [String]

        public init(id: String, title: String, detail: String? = nil, dependsOn: [String] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.dependsOn = dependsOn
        }
    }

    public struct HumanTask: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var why: String
        public var steps: [String]
        public var links: [String]
        public var handover: GoalFile.Handover

        public init(
            id: String,
            title: String,
            why: String,
            steps: [String],
            links: [String] = [],
            handover: GoalFile.Handover = .init(kind: .none)
        ) {
            self.id = id
            self.title = title
            self.why = why
            self.steps = steps
            self.links = links
            self.handover = handover
        }
    }

    public var summary: String
    public var decided: [GoalFile.Item]
    public var outOfScope: [String]
    public var doneWhen: [String]
    public var tasks: [Task]
    public var humanTasks: [HumanTask]

    public init(
        summary: String,
        decided: [GoalFile.Item],
        outOfScope: [String] = [],
        doneWhen: [String],
        tasks: [Task],
        humanTasks: [HumanTask] = []
    ) {
        self.summary = summary
        self.decided = decided
        self.outOfScope = outOfScope
        self.doneWhen = doneWhen
        self.tasks = tasks
        self.humanTasks = humanTasks
    }
}

/// ゴールの案を `goal.json` にする（`docs/renewal/flows.md` の「着手前の確認とゴール」）
public enum GoalFlow {
    /// 案からゴールを作る。人がする作業に依存するタスクはロックして出す（その作業が終わるまで始めない）。
    /// 決まったこと（`decided`）は、回答した質問をすべて、ちょうど 1 回ずつ含む（回答の取りこぼしを防ぐ）
    public static func goal(
        from draft: GoalDraft,
        questions: QuestionsFile,
        version: Int,
        comment: String? = nil
    ) throws(QuestionFlow.ResultError) -> GoalFile {
        let humanTaskIDs = Set(draft.humanTasks.map(\.id))
        let goal = GoalFile(
            version: version,
            summary: draft.summary,
            decided: draft.decided,
            outOfScope: draft.outOfScope,
            doneWhen: draft.doneWhen,
            tasks: draft.tasks.map { task in
                GoalFile.Task(
                    id: task.id,
                    title: task.title,
                    detail: task.detail,
                    dependsOn: task.dependsOn,
                    state: task.dependsOn.contains(where: humanTaskIDs.contains) ? .locked : .pending
                )
            },
            humanTasks: draft.humanTasks.map { task in
                GoalFile.HumanTask(
                    id: task.id, title: task.title, why: task.why, steps: task.steps, links: task.links, handover: task.handover
                )
            },
            comment: comment
        )
        let problems = goal.violations + decidedProblems(draft.decided, questions: questions) + linkProblems(draft.humanTasks)
        guard problems.isEmpty else { throw .invalid(problems) }
        return goal
    }

    private static func decidedProblems(_ decided: [GoalFile.Item], questions: QuestionsFile) -> [String] {
        let answered = questions.questions.filter { $0.state == .answered }.map(\.id)
        let listed = decided.map(\.question)
        var problems: [String] = []
        let missing = answered.filter { !listed.contains($0) }
        if !missing.isEmpty { problems.append("決まったこと（decided）に、回答した質問 \(missing.joined(separator: "・")) が無い") }
        let unknown = listed.filter { !answered.contains($0) }
        if !unknown.isEmpty { problems.append("決まったこと（decided）の \(unknown.joined(separator: "・")) は、回答した質問ではない") }
        let repeated = Set(listed.filter { id in listed.filter { $0 == id }.count > 1 })
        if !repeated.isEmpty { problems.append("決まったこと（decided）で \(repeated.sorted().joined(separator: "・")) が重なっている") }
        problems += decided.filter { $0.text.isEmpty }.map { "決まったこと（decided）の \($0.question) の text が空" }
        return problems
    }

    /// 人に開いてもらうリンクは https だけ
    private static func linkProblems(_ humanTasks: [GoalDraft.HumanTask]) -> [String] {
        humanTasks.flatMap { task in
            task.links.filter { URL(string: $0)?.scheme != "https" }.map { "\(task.id): リンク \($0) は https でない" }
        }
    }
}
