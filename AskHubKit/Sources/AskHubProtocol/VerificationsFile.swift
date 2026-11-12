import Foundation

/// 実機確認への答え（`repos/<owner>/<repo>/epics/<epic>/verifications.json`）。司令塔だけが書く。
///
/// 何を確かめるかはゴールの完了の条件（`VerificationTarget`）で、ここには人が答えた項目だけを、答えた順に置く。
/// 1 つの項目に答えるのは 1 回だけ（答え直さない）
public struct VerificationsFile: StateFile {
    public static let formatVersion = 1

    public struct Answer: Codable, Equatable, Sendable {
        /// 項目の id（`v1` など）
        public var id: String
        public var result: VerifyIntent.Result
        /// 問題の説明（「問題あり」だけ。「確認した」は空）
        public var note: String
        public var intent: IntentReference
        public var at: Timestamp

        public init(id: String, result: VerifyIntent.Result, note: String = "", intent: IntentReference, at: Timestamp) {
            self.id = id
            self.result = result
            self.note = note
            self.intent = intent
            self.at = at
        }
    }

    public var answers: [Answer]

    public init(answers: [Answer] = []) {
        self.answers = answers
    }

    /// 項目への答え。まだ答えていなければ nil
    public func answer(_ item: String) -> Answer? {
        answers.first { $0.id == item }
    }

    public var violations: [String] {
        var problems: [String] = []
        if Set(answers.map(\.id)).count != answers.count { problems.append("同じ項目への答えが重なっている") }
        for answer in answers {
            if VerificationTarget.index(of: answer.id) == nil { problems.append("\(answer.id) は項目の id の形でない") }
            if answer.note.unicodeScalars.count > VerifyIntent.maximumNoteLength {
                problems.append("\(answer.id) の note が \(VerifyIntent.maximumNoteLength) 文字を超える")
            }
            if answer.result == .problem && answer.note.isEmpty { problems.append("\(answer.id) は問題ありなのに note が空") }
        }
        return problems
    }
}
