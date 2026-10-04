import Foundation

/// 質問への回答（アプリが投稿する返信の本文）。
///
/// ```text
/// 回答: <選んだ選択肢>
/// <任意の自由記述>
/// ```
///
/// 選択肢の無い質問は自由記述だけを書く。詳細は `docs/protocol.md` の「回答の形式」を参照。
public struct Answer: Sendable, Equatable {
    /// 選んだ選択肢。選択肢の無い質問では `nil`
    public var choice: String?
    /// 自由記述（補足・条件など）
    public var note: String

    public init(choice: String? = nil, note: String = "") {
        self.choice = choice
        self.note = note
    }

    /// 返信の本文から回答を読み取る。1 行目が `回答: ` で始まらなければ、全体を自由記述とみなす
    public init(parsing body: String) {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix(Self.choicePrefix) {
            let choice = first.dropFirst(Self.choicePrefix.count).trimmingCharacters(in: .whitespaces)
            self.init(
                choice: choice.isEmpty ? nil : choice,
                note: lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            self.init(note: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 投稿する返信の本文
    public var body: String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let choice else {
            return note
        }
        let choiceLine = Self.choicePrefix + choice
        return note.isEmpty ? choiceLine : "\(choiceLine)\n\(note)"
    }

    /// この質問への回答として投稿してよい形か。
    ///
    /// 選択肢のある質問では、選択肢のいずれか 1 つを選んでいること。
    /// 選択肢の無い質問では、選択肢を持たず自由記述が空でないこと。
    public func isValid(for marker: QuestionMarker) -> Bool {
        if marker.isFreeForm {
            return choice == nil && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let choice else {
            return false
        }
        return marker.options.contains(choice)
    }

    static let choicePrefix = "回答: "
}
