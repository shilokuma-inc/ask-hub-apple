import Foundation

/// 人の意図への参照（`intents/<keyId>/<nonce>.json`）
public struct IntentReference: Codable, Hashable, Sendable {
    public var keyId: KeyID
    public var nonce: ULID

    public init(keyId: KeyID, nonce: ULID) {
        self.keyId = keyId
        self.nonce = nonce
    }
}

public enum QuestionState: String, Codable, Sendable, CaseIterable {
    /// 依存先の回答を待っている
    case locked
    /// 依存先が決まり、見直している
    case revising
    /// 回答を待っている
    case open
    /// 説明を作っている
    case clarifying
    /// 人が回答した。判断はすべて人がするので、推奨の選択肢で決めたことにする状態は持たない
    case answered
    /// 依存先が決まって見直した結果、要らなくなった。回答しない（理由は `revision` に書く）
    case dropped

    /// 決まった（回答した・要らなくなった）。依存する質問の見直しと、着手前の確認に進める
    public var isSettled: Bool {
        switch self {
        case .answered, .dropped: true
        case .locked, .revising, .open, .clarifying: false
        }
    }
}

/// `repos/<owner>/<repo>/epics/<epic>/questions.json`（質問とその状態）。司令塔だけが書く
public struct QuestionsFile: StateFile {
    public static let formatVersion = 1

    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        /// その選択肢で何が変わるか
        public var effect: String

        public init(label: String, effect: String) {
            self.label = label
            self.effect = effect
        }
    }

    /// 「説明を求める」と、その説明。`text` は説明を作っている間は nil
    public struct Explanation: Codable, Equatable, Sendable {
        public var asked: IntentReference
        public var note: String
        public var text: String?
        public var at: Timestamp

        public init(asked: IntentReference, note: String, text: String? = nil, at: Timestamp) {
            self.asked = asked
            self.note = note
            self.text = text
            self.at = at
        }
    }

    public enum RevisionCause: String, Codable, Sendable, CaseIterable {
        /// 説明のついでに直した
        case explain
        /// 依存先が決まって見直した
        case dependency
    }

    /// 最後に書き直したときの記録
    public struct Revision: Codable, Equatable, Sendable {
        public var from: Int
        public var reason: String
        public var by: RevisionCause

        public init(from: Int, reason: String, by: RevisionCause) {
            self.from = from
            self.reason = reason
            self.by = by
        }
    }

    /// 受け付けた回答。`choice` は選んだ選択肢（自由記述だけなら nil）
    public struct Answer: Codable, Equatable, Sendable {
        public var choice: String?
        public var note: String
        public var intent: IntentReference
        public var at: Timestamp

        public init(choice: String?, note: String = "", intent: IntentReference, at: Timestamp) {
            self.choice = choice
            self.note = note
            self.intent = intent
            self.at = at
        }
    }

    public struct Question: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        /// 書き直すたびに上げる。回答の人の意図は、回答した質問の版を持つ
        public var version: Int
        public var title: String
        /// なぜ決める必要があるか
        public var why: String
        public var options: [Option]
        public var recommended: String
        /// 推奨の理由
        public var reason: String
        /// 慎重に決めてほしい理由。無ければ nil
        public var caution: Caution?
        public var dependsOn: [String]
        /// 何回目の質問づくりで出た質問か（最初が 1）
        public var round: Int
        public var state: QuestionState
        /// Discussion の質問の写しのコメントの id（GraphQL の node id）
        public var comment: String?
        public var explanations: [Explanation]
        public var revision: Revision?
        public var answer: Answer?
        /// 実装の途中の質問なら、質問したジョブ（開始前の質問は nil）
        public var job: ULID?
        /// 実装の途中の質問なら、どのタスクの実装の途中か（開始前の質問と、最終 PR の直しの質問は nil）
        public var task: String?

        public init(
            id: String,
            version: Int = 1,
            title: String,
            why: String,
            options: [Option],
            recommended: String,
            reason: String,
            caution: Caution? = nil,
            dependsOn: [String] = [],
            round: Int = 1,
            state: QuestionState,
            comment: String? = nil,
            explanations: [Explanation] = [],
            revision: Revision? = nil,
            answer: Answer? = nil,
            job: ULID? = nil,
            task: String? = nil
        ) {
            self.id = id
            self.version = version
            self.title = title
            self.why = why
            self.options = options
            self.recommended = recommended
            self.reason = reason
            self.caution = caution
            self.dependsOn = dependsOn
            self.round = round
            self.state = state
            self.comment = comment
            self.explanations = explanations
            self.revision = revision
            self.answer = answer
            self.job = job
            self.task = task
        }

        /// 実装の途中の質問か（質問したジョブを持つ）
        public var isDuringImplementation: Bool { job != nil }
    }

    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    /// その質問に直接依存する質問の id（並びはファイルの順）
    public func dependents(of id: String) -> [String] {
        questions.filter { $0.dependsOn.contains(id) }.map(\.id)
    }

    public var violations: [String] {
        let dependencies = Dictionary(questions.map { ($0.id, $0.dependsOn) }) { first, _ in first }
        var violations = LocalIDs.problems(questions.map(\.id), dependencies: dependencies)
        let states = Dictionary(questions.map { ($0.id, $0.state) }) { first, _ in first }
        for question in questions {
            violations += Self.problems(of: question)
            // ロックを外すのは、依存先がすべて決まってから（依存先の回答を変えたら、ロックに戻す）
            let waiting = question.dependsOn.filter { states[$0]?.isSettled == false }
            if question.state != .locked && !waiting.isEmpty {
                violations.append("\(question.id): 依存先（\(waiting.joined(separator: "・"))）が決まる前にロックを外している")
            }
        }
        return violations
    }

    private static func problems(of question: Question) -> [String] {
        var problems: [String] = []
        let name = question.id
        if question.version < 1 || question.round < 1 { problems.append("\(name): version と round は 1 以上") }
        if question.title.isEmpty || question.why.isEmpty || question.reason.isEmpty { problems.append("\(name): title・why・reason が空") }
        let labels = question.options.map(\.label)
        if labels.isEmpty || labels.contains(where: \.isEmpty) || Set(labels).count != labels.count {
            problems.append("\(name): 選択肢が無い・空・重複")
        }
        if !labels.contains(question.recommended) { problems.append("\(name): 推奨が選択肢に無い") }
        problems += (question.caution?.problems ?? []).map { "\(name): \($0)" }
        if question.state == .locked && question.dependsOn.isEmpty { problems.append("\(name): 依存先の無い質問はロックできない") }
        if let task = question.task, !LocalIDs.isValid(task) { problems.append("\(name): task の形が違う") }
        if question.task != nil, question.job == nil { problems.append("\(name): task は実装の途中の質問（job がある）だけが持つ") }
        if question.state == .dropped && question.revision?.by != .dependency {
            problems.append("\(name): 要らなくなった質問は、依存先の見直しの理由が要る")
        }
        if let revision = question.revision, revision.from >= question.version { problems.append("\(name): revision.from は今の版より前") }
        problems += explanationProblems(of: question)
        problems += answerProblems(of: question, labels: labels)
        return problems
    }

    /// 説明を待つ問い（`text` が nil）は、説明を作っている質問の最後の 1 つだけ
    private static func explanationProblems(of question: Question) -> [String] {
        let pending = question.explanations.indices.filter { question.explanations[$0].text == nil }
        if question.state == .clarifying {
            return pending == [question.explanations.count - 1] ? [] : ["\(question.id): 説明を作っている問いが無い"]
        }
        return pending.isEmpty ? [] : ["\(question.id): 説明を作っていない質問に、説明を待つ問いがある"]
    }

    /// 回答は answered のときだけ持つ
    private static func answerProblems(of question: Question, labels: [String]) -> [String] {
        let name = question.id
        switch (question.state, question.answer) {
        case let (.answered, answer?):
            let isChoice = answer.choice.map(labels.contains) ?? !answer.note.isEmpty
            return isChoice ? [] : ["\(name): 回答は、選択肢か自由記述が要る"]
        case (.answered, nil):
            return ["\(name): 回答が無い"]
        case (_, .some):
            return ["\(name): \(question.state.rawValue) の質問は回答を持たない"]
        case (_, nil):
            return []
        }
    }
}

public enum TaskState: String, Codable, Sendable, CaseIterable {
    case pending
    /// 人がする作業の待ち
    case locked
    case running
    case done
}

public enum HumanTaskState: String, Codable, Sendable, CaseIterable {
    case pending
    case done
}

/// 人がする作業が終わったら渡すもの
public enum HandoverKind: String, Codable, Sendable, CaseIterable {
    /// 「終わった」を押すだけ
    case none
    /// ファイルを渡す
    case file
    /// GitHub の Secrets に入れる（値はどこにも残さない）
    case secret
}

/// `repos/<owner>/<repo>/epics/<epic>/goal.json`（ゴール）。司令塔だけが書く
public struct GoalFile: StateFile {
    public static let formatVersion = 1

    /// 決まったこと（どの質問から来たか）
    public struct Item: Codable, Equatable, Sendable {
        public var question: String
        public var text: String

        public init(question: String, text: String) {
            self.question = question
            self.text = text
        }
    }

    public struct Task: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?
        /// ほかのタスクと、人がする作業の id
        public var dependsOn: [String]
        public var state: TaskState

        public init(id: String, title: String, detail: String? = nil, dependsOn: [String] = [], state: TaskState = .pending) {
            self.id = id
            self.title = title
            self.detail = detail
            self.dependsOn = dependsOn
            self.state = state
        }
    }

    public struct Handover: Codable, Equatable, Sendable {
        public var kind: HandoverKind
        /// `secret` のときの GitHub の Secrets の名前
        public var name: String?

        public init(kind: HandoverKind, name: String? = nil) {
            self.kind = kind
            self.name = name
        }
    }

    public struct HumanTask: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var why: String
        public var steps: [String]
        public var links: [String]
        public var handover: Handover
        public var state: HumanTaskState

        public init(
            id: String,
            title: String,
            why: String,
            steps: [String],
            links: [String] = [],
            handover: Handover = Handover(kind: .none),
            state: HumanTaskState = .pending
        ) {
            self.id = id
            self.title = title
            self.why = why
            self.steps = steps
            self.links = links
            self.handover = handover
            self.state = state
        }
    }

    /// 直すたびに上げる。「開始」の人の意図は、確かめたゴールの版を持つ
    public var version: Int
    public var summary: String
    public var decided: [Item]
    public var outOfScope: [String]
    public var doneWhen: [String]
    public var tasks: [Task]
    public var humanTasks: [HumanTask]
    /// 最後のゴールの修正で、反映しなかった人の指示とその理由（決まったことを変える指示など）。人に出す
    public var notApplied: [String]?
    /// Discussion のゴールの写しのコメントの id
    public var comment: String?

    public init(
        version: Int = 1,
        summary: String,
        decided: [Item] = [],
        outOfScope: [String] = [],
        doneWhen: [String],
        tasks: [Task],
        humanTasks: [HumanTask] = [],
        notApplied: [String]? = nil,
        comment: String? = nil
    ) {
        self.version = version
        self.summary = summary
        self.decided = decided
        self.outOfScope = outOfScope
        self.doneWhen = doneWhen
        self.tasks = tasks
        self.humanTasks = humanTasks
        self.notApplied = notApplied
        self.comment = comment
    }

    public var violations: [String] {
        let dependencies = Dictionary(tasks.map { ($0.id, $0.dependsOn) }) { first, _ in first }
        var violations = LocalIDs.problems(tasks.map(\.id) + humanTasks.map(\.id), dependencies: dependencies)
        if version < 1 { violations.append("version は 1 以上") }
        if summary.isEmpty || doneWhen.isEmpty || tasks.isEmpty { violations.append("summary・doneWhen・tasks が空") }
        if notApplied?.contains(where: \.isEmpty) == true { violations.append("notApplied に空の行がある") }
        for task in tasks where task.title.isEmpty {
            violations.append("\(task.id): title が空")
        }
        for humanTask in humanTasks {
            violations += Self.problems(of: humanTask)
        }
        return violations
    }

    private static func problems(of humanTask: HumanTask) -> [String] {
        var problems: [String] = []
        if humanTask.title.isEmpty || humanTask.why.isEmpty || humanTask.steps.isEmpty {
            problems.append("\(humanTask.id): title・why・steps が空")
        }
        switch humanTask.handover.kind {
        case .secret:
            if !humanTask.handover.name.map(isSecretName).orFalse { problems.append("\(humanTask.id): Secrets の名前の形が違う") }
        case .none, .file:
            if humanTask.handover.name != nil { problems.append("\(humanTask.id): secret でない渡し方に名前がある") }
        }
        return problems
    }

    /// GitHub の Secrets の名前（英大文字・数字・`_`。数字と `GITHUB_` で始まらない）
    static func isSecretName(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first), !name.hasPrefix("GITHUB_") else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

/// 質問・タスクなどの epic の中の id（英小文字で始まり、英小文字・数字・ハイフンで 1〜32 文字）と、その間の依存
enum LocalIDs {
    static func isValid(_ id: String) -> Bool {
        guard (1...32).contains(id.utf8.count), let first = id.utf8.first, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first) else {
            return false
        }
        return id.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    /// id の形・重複と、依存先の実在・自分自身への依存・循環を確かめる。`ids` は依存先として書ける id のすべて
    static func problems(_ ids: [String], dependencies: [String: [String]]) -> [String] {
        var problems: [String] = []
        for id in ids where !isValid(id) {
            problems.append("\(id): id の形が違う")
        }
        if Set(ids).count != ids.count { problems.append("id が重複している") }
        let known = Set(ids)
        for (id, dependsOn) in dependencies.sorted(by: { $0.key < $1.key }) {
            if dependsOn.contains(id) { problems.append("\(id): 自分自身に依存している") }
            for target in dependsOn where !known.contains(target) {
                problems.append("\(id): 依存先 \(target) が無い")
            }
            if Set(dependsOn).count != dependsOn.count { problems.append("\(id): 依存先が重複している") }
        }
        if let cycle = cycle(in: dependencies) { problems.append("依存が循環している（\(cycle.joined(separator: " → "))）") }
        return problems
    }

    /// 依存の循環を 1 つ見つけて返す（無ければ nil）。自分自身への依存は別に数えるので除く
    static func cycle(in dependencies: [String: [String]]) -> [String]? {
        var state: [String: Bool] = [:] // false: 調べている途中、true: 調べ終わった
        var path: [String] = []
        func visit(_ id: String) -> [String]? {
            if state[id] == true { return nil }
            if state[id] == false, let start = path.firstIndex(of: id) { return Array(path[start...]) + [id] }
            state[id] = false
            path.append(id)
            for next in dependencies[id] ?? [] where next != id {
                if let found = visit(next) { return found }
            }
            path.removeLast()
            state[id] = true
            return nil
        }
        for id in dependencies.keys.sorted() {
            if let found = visit(id) { return found }
        }
        return nil
    }
}
