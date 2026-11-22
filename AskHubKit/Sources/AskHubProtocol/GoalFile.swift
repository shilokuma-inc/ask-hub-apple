import Foundation

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
