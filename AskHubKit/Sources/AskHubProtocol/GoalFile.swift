import Foundation

public enum TaskState: String, Codable, Sendable, CaseIterable {
    case pending
    /// 人がする作業の待ち
    case locked
    case running
    case done
    /// 人が飛ばした（ワーカーにできない・やらない）。済んだものとして先へ進む
    case skipped

    /// 済んだ（実装した・人が飛ばした）。依存するタスクを始められ、すべてが済めば最終 PR の段取りに進む
    public var isSettled: Bool {
        switch self {
        case .done, .skipped: true
        case .pending, .locked, .running: false
        }
    }
}

/// タスクを飛ばした理由
public enum TaskSkipReason: String, Codable, Sendable, CaseIterable {
    /// 人が別にやる（別のリポジトリの PR など、ワーカーの作業場所の外の作業）
    case handledElsewhere
    /// やらない
    case notNeeded
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
        /// 飛ばした記録。`skipped` のタスクだけが持つ
        public var skip: Skip?

        public init(
            id: String,
            title: String,
            detail: String? = nil,
            dependsOn: [String] = [],
            state: TaskState = .pending,
            skip: Skip? = nil
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.dependsOn = dependsOn
            self.state = state
            self.skip = skip
        }
    }

    /// タスクを飛ばした記録（司令塔が `skipTask` の意図を受け付けたときに書く）
    public struct Skip: Codable, Equatable, Sendable {
        public var reason: TaskSkipReason
        /// 人のメモ。無ければ nil
        public var note: String?
        public var intent: IntentReference
        public var at: Timestamp
        /// 飛ばしたときに開いていた子 PR（レビュー・直しのジョブの子 PR）。最終 PR を出すときに閉じる。子 PR を作る前なら nil
        public var pullRequest: Int?

        public init(reason: TaskSkipReason, note: String? = nil, intent: IntentReference, at: Timestamp, pullRequest: Int? = nil) {
            self.reason = reason
            self.note = note
            self.intent = intent
            self.at = at
            self.pullRequest = pullRequest
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

    /// 人がする作業を終えた記録（司令塔が `humanTaskDone` の意図を受け付けたときに書く）
    public struct Completion: Codable, Equatable, Sendable {
        public var intent: IntentReference
        public var at: Timestamp
        /// 渡されたファイル（`file` の作業。中身は `attachments/<device>/<nonce>/<n>`）。「終わった」だけなら nil
        public var file: RequestAttachment?

        public init(intent: IntentReference, at: Timestamp, file: RequestAttachment? = nil) {
            self.intent = intent
            self.at = at
            self.file = file
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
        /// 終えた記録。終える前は nil
        public var done: Completion?

        public init(
            id: String,
            title: String,
            why: String,
            steps: [String],
            links: [String] = [],
            handover: Handover = Handover(kind: .none),
            state: HumanTaskState = .pending,
            done: Completion? = nil
        ) {
            self.id = id
            self.title = title
            self.why = why
            self.steps = steps
            self.links = links
            self.handover = handover
            self.state = state
            self.done = done
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

    /// `task` を飛ばすと、すべてのタスクが済み、実装した（`done` の）タスクが 1 つも無いか。最終 PR に入れるものが無いので、飛ばさせない
    /// （epic ごとやめるなら「やめる」）。司令塔とクライアントで同じ扱いにする
    public func skippingLeavesNothing(_ task: String) -> Bool {
        !tasks.contains { $0.state == .done } && tasks.allSatisfy { $0.id == task || $0.state.isSettled }
    }

    public var violations: [String] {
        let dependencies = Dictionary(tasks.map { ($0.id, $0.dependsOn) }) { first, _ in first }
        var violations = LocalIDs.problems(tasks.map(\.id) + humanTasks.map(\.id), dependencies: dependencies)
        if version < 1 { violations.append("version は 1 以上") }
        if summary.isEmpty || doneWhen.isEmpty || tasks.isEmpty { violations.append("summary・doneWhen・tasks が空") }
        if notApplied?.contains(where: \.isEmpty) == true { violations.append("notApplied に空の行がある") }
        for task in tasks {
            violations += Self.problems(of: task)
        }
        for humanTask in humanTasks {
            violations += Self.problems(of: humanTask)
        }
        return violations
    }

    private static func problems(of task: Task) -> [String] {
        var problems: [String] = []
        if task.title.isEmpty { problems.append("\(task.id): title が空") }
        if (task.state == .skipped) != (task.skip != nil) { problems.append("\(task.id): 飛ばした記録は skipped のタスクだけが持つ") }
        if let note = task.skip?.note, note.isEmpty || note.unicodeScalars.count > SkipTaskIntent.maximumNoteLength {
            problems.append("\(task.id): 飛ばしたときのメモが空か長すぎる（無ければ書かない。\(SkipTaskIntent.maximumNoteLength) 文字まで）")
        }
        if let number = task.skip?.pullRequest, number < 1 { problems.append("\(task.id): 飛ばしたときの子 PR の番号が 1 より小さい") }
        return problems
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
        if (humanTask.state == .done) != (humanTask.done != nil) { problems.append("\(humanTask.id): 終えた記録は done の作業だけが持つ") }
        if humanTask.done?.file != nil, humanTask.handover.kind != .file { problems.append("\(humanTask.id): file でない作業にファイルがある") }
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
