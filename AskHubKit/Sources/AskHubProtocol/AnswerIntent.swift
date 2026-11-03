import Foundation

/// 回答の人の意図（封筒の `kind` が `answer`）。封筒の `target`・`targetVersion`・`payload` を回答として読んだもの。
///
/// 署名を確かめた後に読む。知らない欄のある `payload` は、一部だけを指示として扱わないよう、読まない
public struct AnswerIntent: Equatable, Sendable {
    /// 回答の仕方。判断はすべて人がするので、推奨の選択肢で決めたことにする仕方は持たない
    public enum Mode: String, Sendable, CaseIterable {
        /// 選択肢か自由記述で答える
        case answer
        /// 説明を求める。`note` が人の問い
        case clarify
    }

    /// 回答の形でない（理由つき）
    public struct Malformed: Error, Equatable, Sendable {
        public var detail: String
    }

    public static let kind = "answer"
    public static let targetType = "question"
    /// 選択肢と自由記述の長さの上限（Unicode のコードポイントの数。JSON Schema の maxLength と同じ数え方）
    public static let maximumChoiceLength = 1000
    public static let maximumNoteLength = 10000

    public var repo: RepositoryFullName
    public var epic: ULID
    public var question: String
    /// 回答した質問の版
    public var questionVersion: Int
    public var mode: Mode
    /// 選んだ選択肢。自由記述だけ・説明を求めるときは nil
    public var choice: String?
    public var note: String
    public var intent: IntentReference

    public init(
        repo: RepositoryFullName,
        epic: ULID,
        question: String,
        questionVersion: Int,
        mode: Mode,
        choice: String? = nil,
        note: String = "",
        intent: IntentReference
    ) {
        self.repo = repo
        self.epic = epic
        self.question = question
        self.questionVersion = questionVersion
        self.mode = mode
        self.choice = choice
        self.note = note
        self.intent = intent
    }

    /// 確かめた封筒から読む
    public init(envelope: IntentEnvelope) throws(Malformed) {
        guard envelope.kind == Self.kind else { throw Malformed(detail: "kind が answer でない") }
        guard let repo = envelope.repo else { throw Malformed(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, let epic = target.epic, let question = target.id else {
            throw Malformed(detail: "target が質問でない")
        }
        guard let version = envelope.targetVersion.flatMap(Self.version) else { throw Malformed(detail: "targetVersion が質問の版でない") }
        let payload = envelope.payload ?? [:]
        guard Set(payload.keys).isSubset(of: ["mode", "choice", "note"]) else { throw Malformed(detail: "payload に知らない欄がある") }
        guard let mode = payload["mode"]?.stringValue.flatMap(Mode.init(rawValue:)) else { throw Malformed(detail: "mode が無い・知らない値") }
        let choice = try Self.text(payload["choice"], name: "choice", nullable: true, limit: Self.maximumChoiceLength)
        let note = try Self.text(payload["note"], name: "note", nullable: false, limit: Self.maximumNoteLength) ?? ""
        switch mode {
        case .answer where choice == nil && note.isEmpty:
            throw Malformed(detail: "回答に選択肢も自由記述も無い")
        case .clarify where choice != nil:
            throw Malformed(detail: "clarify に choice がある")
        default:
            break
        }
        self.init(
            repo: repo,
            epic: epic,
            question: question,
            questionVersion: version,
            mode: mode,
            choice: choice,
            note: note,
            intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        )
    }

    /// 封筒の `target`
    public var target: IntentEnvelope.Target { .init(type: Self.targetType, epic: epic, id: question) }
    /// 封筒の `targetVersion`（質問の版を 10 進で）
    public var targetVersion: String { String(questionVersion) }

    /// 封筒の `payload`。空の自由記述と、無い選択肢は書かない
    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = ["mode": .string(mode.rawValue)]
        if let choice { payload["choice"] = .string(choice) }
        if !note.isEmpty { payload["note"] = .string(note) }
        return payload
    }

    /// 1 以上の 10 進の整数（先頭の 0・符号を受け付けない）
    private static func version(_ text: String) -> Int? {
        guard let first = text.utf8.first, first != UInt8(ascii: "0"),
              text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(text)
    }

    /// 文字列の欄を読む。無い欄は nil。`nullable` なら null も nil。空の選択肢は受け付けない
    private static func text(_ value: JSONValue?, name: String, nullable: Bool, limit: Int) throws(Malformed) -> String? {
        switch value {
        case nil:
            return nil
        case .null? where nullable:
            return nil
        case let .string(text)? where text.unicodeScalars.count <= limit && !(nullable && text.isEmpty):
            return text
        default:
            throw Malformed(detail: "\(name) が文字列でない・空・長すぎる")
        }
    }
}
