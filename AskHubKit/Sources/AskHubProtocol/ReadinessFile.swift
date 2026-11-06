import Foundation

/// 着手前の確認の結果の種類
public enum ReadinessVerdict: String, Codable, Sendable, CaseIterable {
    /// 進めてよい（ゴールを作った）
    case ready
    /// 追加の質問が要る
    case moreQuestions
    /// 1 つの epic に収まらない。追加の質問を使い切って決めきれないときも、理由を書いてこれにする
    case tooLarge
}

/// `repos/<owner>/<repo>/epics/<epic>/readiness.json`（最後の着手前の確認の結果）。司令塔だけが書く。
///
/// 1 つの epic に収まらないときは、分け方の案を人に出し、「分けて依頼し直す」か「このまま 1 つで進める」かを選んでもらう
/// （`decideSplit` の人の意図。`targetVersion` はこのファイルの `version`）
public struct ReadinessFile: StateFile {
    public static let formatVersion = 1

    /// 分け方の案の 1 つ
    public struct Part: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String

        public init(title: String, summary: String) {
            self.title = title
            self.summary = summary
        }
    }

    /// 確かめるたびに上げる
    public var version: Int
    public var verdict: ReadinessVerdict
    public var reason: String
    /// 分け方の案。大きすぎるときだけ。決めきれないときは空のこともある
    public var split: [Part]
    /// 何回目の質問づくりの後の確認か
    public var round: Int
    /// 人が分け方の判断で「このまま 1 つで進める」を選んだ後の確認か。選んだ後は大きすぎるとは返さず、後の確認にも引き継ぐ。無ければ false
    public var proceeding: Bool?
    public var checkedAt: Timestamp

    public init(
        version: Int,
        verdict: ReadinessVerdict,
        reason: String,
        split: [Part] = [],
        round: Int,
        proceeding: Bool? = nil,
        checkedAt: Timestamp
    ) {
        self.version = version
        self.verdict = verdict
        self.reason = reason
        self.split = split
        self.round = round
        self.proceeding = proceeding
        self.checkedAt = checkedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if version < 1 || round < 1 { violations.append("version と round は 1 以上") }
        if reason.isEmpty { violations.append("reason が空") }
        if verdict != .tooLarge && !split.isEmpty { violations.append("大きすぎるときだけ split を持つ") }
        if split.contains(where: { $0.title.isEmpty || $0.summary.isEmpty }) { violations.append("split の title・summary が空") }
        if proceeding == true && verdict == .tooLarge { violations.append("このまま進めると決めた後は tooLarge にしない") }
        return violations
    }
}
