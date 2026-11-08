import Foundation

/// 人に決めてもらう質問。epic ごとに Q1・Q2… と番号を振る
struct Question: Identifiable, Hashable {
    /// epic の中の id（例: Q3）
    let id: String
    var title: String
    /// なぜ決める必要があるか（必須の欄）
    var why: String
    /// 選択肢。空なら自由記述の質問
    var options: [Option] = []
    var recommendedOptionID: Option.ID?
    /// 推奨の理由（必須の欄）
    var recommendationReason: String?
    /// 前提にする質問（この質問は、依存先がすべて決まるまで答えられない）
    var dependsOn: [Question.ID] = []
    var state: State = .open
    /// 説明を求めた履歴。何往復でもできる
    var explanations: [Explanation] = []
    /// 説明や見直しで、Claude が質問文や選択肢を書き直したときの説明。画面で分かるように出す
    var revisionNote: String?
    var askedAt: Date
    /// 慎重に決めてほしい理由（セキュリティなど）。あれば札を警告ふうに出す
    var caution: Caution?
    /// 実装の途中で Claude が聞いた質問なら、どこで出たか（開始する前の質問は nil）。答えるまで、その epic は止まっている
    var during: ImplementationPoint?

    struct Option: Identifiable, Hashable {
        let id: String
        var label: String
        /// 選んだら何が変わるか（必須の欄）
        var effect: String
    }

    enum State: Hashable {
        case open
        /// 説明を求めた。Claude がリポジトリを読んで書いている
        case awaitingExplanation(requestedAt: Date)
        /// 依存先が決まるまで答えられない
        case locked
        /// 依存先が決まり、Claude が見直している（終わるとロックが外れる）
        case reviewing
        case answered(Response)
    }

    struct Response: Hashable {
        var optionID: Option.ID?
        /// 補足（自由記述の質問では回答そのもの）
        var note: String
        var answeredAt: Date
    }

    /// 実装の途中の質問が出た所
    enum ImplementationPoint: Hashable {
        /// タスクの実装・直しの途中（番号はゴールの並びの順）
        case task(number: Int, title: String)
        /// 最終 PR の直しの途中
        case finalPullRequest

        /// 例: タスク 2「並べ替えのボタン」の実装
        var label: String {
            switch self {
            case let .task(number, title): "タスク \(number)「\(title)」の実装"
            case .finalPullRequest: "最終 PR の直し"
            }
        }
    }

    struct Explanation: Hashable {
        /// 何が分からないか（空でもよい）
        var request: String
        var requestedAt: Date
        /// 説明の本文。書き終わるまで nil
        var body: String?
        var answeredAt: Date?
    }
}

extension Question {
    var isFreeText: Bool { options.isEmpty }

    /// いま答えられるか
    var isAnswerable: Bool { state == .open }

    /// 回答済みで、決まっているか（判断はいつも人がする）
    var isSettled: Bool {
        switch state {
        case .answered:
            return true

        case .open, .awaitingExplanation, .locked, .reviewing:
            return false
        }
    }

    var isAwaitingExplanation: Bool {
        if case .awaitingExplanation = state {
            return true
        }
        return false
    }

    var recommendedOption: Option? {
        options.first { $0.id == recommendedOptionID }
    }

    /// 回答した選択肢（自由記述・未回答なら nil）
    var answeredOption: Option? {
        guard case .answered(let response) = state else {
            return nil
        }
        return options.first { $0.id == response.optionID }
    }

    /// 最後に届いた説明
    var latestExplanation: Explanation? {
        explanations.last { $0.body != nil }
    }
}

extension [Question] {
    /// この質問に依存している質問（「この回答で Q4・Q5 が決まります」）
    func dependents(of question: Question) -> [Question] {
        filter { $0.dependsOn.contains(question.id) }
    }

    func question(_ id: Question.ID) -> Question? {
        first { $0.id == id }
    }
}
