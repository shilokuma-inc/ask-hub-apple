import AskHubProtocol
import Foundation

/// 質問の一覧の移り変わり（`docs/renewal/flows.md` の「質問と回答」「司令塔の動き」）。
///
/// 司令塔が使う。状態リポジトリへの読み書きとジョブの作成はせず、新しい `questions.json` と、
/// 司令塔がすること（`Effect`）を返すだけにする（同じ入力なら同じ結果になり、テストで確かめられる）
public enum QuestionFlow {
    /// 回答の人の意図を受け付けなかった理由
    public enum Rejection: Error, Equatable, Sendable {
        case malformed(String)
        /// 宛先のリポジトリ・epic が違う
        case otherEpic
        case notAcceptingAnswers(EpicStage)
        case unknownQuestion(String)
        /// 質問が書き直された後の、古い版への回答
        case staleVersion(question: String, current: Int)
        case notAnswerable(question: String, state: QuestionState)
        case unknownChoice(question: String)
        /// 実装の途中の質問は、答えで作業を再開したので、答え直せない・説明を求められない
        case resumed(question: String)

        /// 処理した記録（`consumed`）の `reason` に書き、クライアントに出す文
        public var reason: String {
            switch self {
            case let .malformed(detail):
                "回答の形が違う（\(detail)）"
            case .otherEpic:
                "宛先の epic が違う"
            case let .notAcceptingAnswers(stage):
                Self.reason(for: stage)
            case let .unknownQuestion(question):
                "質問 \(question) が無い"
            case let .staleVersion(question, current):
                "質問 \(question) は書き直された（今の版は \(current)）。新しい質問に答え直す"
            case let .notAnswerable(question, state):
                Self.reason(for: question, in: state)
            case let .unknownChoice(question):
                "質問 \(question) に、選んだ選択肢が無い"
            case let .resumed(question):
                "質問 \(question) は実装の途中の質問で、答えで作業を再開した（答え直し・説明はできない。変えるときは最終 PR への指示として出す）"
            }
        }

        private static func reason(for stage: EpicStage) -> String {
            switch stage {
            case .drafting: "まだ質問を作っている"
            case .running, .finalizing, .reviewing: "開始した後は回答を変えられない（最終 PR への指示として出す）"
            case .merged, .abandoned: "epic は終わっている"
            case .asking, .checking, .awaitingSplit, .awaitingStart: "回答を受け付けている"
            }
        }

        private static func reason(for question: String, in state: QuestionState) -> String {
            switch state {
            case .locked: "質問 \(question) は、依存先の回答を待っている"
            case .revising: "質問 \(question) は、依存先の回答を受けて見直している"
            case .clarifying: "質問 \(question) は、説明を作っている"
            case .dropped: "質問 \(question) は、見直しで要らなくなった"
            case .answered: "質問 \(question) は回答済みなので、説明を求められない（変えるときは答え直す）"
            case .open: "質問 \(question) は回答を待っている"
            }
        }
    }

    /// Claude の結果を書けなかった理由
    public enum ResultError: Error, Equatable, Sendable {
        /// 頼んだ後に状態が変わり、結果が当てはまらない。捨てる
        case stale
        /// 結果が決まりに合わない。同じ会話を再開して直させる
        case invalid([String])
    }

    /// 司令塔がすること
    public enum Effect: Equatable, Sendable {
        /// `explain` のジョブを作る
        case explain(question: String, asked: IntentReference)
        /// `reviseQuestion` のジョブを作る。`basis` をジョブの入力に入れ、結果を書くときに渡す
        case revise(question: String, basis: RevisionBasis)
        /// その質問の `explain`・`reviseQuestion` のジョブがまだ動いていれば止める（結果は書いても捨てられる）
        case cancel(question: String)
        /// epic を `asking` に戻す。動いている着手前の確認と、ゴールの案は捨てる
        case reopen
        /// epic を `checking` にし、`checkReadiness` のジョブを作る
        case checkReadiness
        /// 実装の途中の質問の答えで、質問したジョブ（`job`）と同じ種類のジョブを作って再開する
        case resume(question: String, job: ULID)
    }

    /// 見直しの結果
    public enum RevisionOutcome: Equatable, Sendable {
        /// そのままでよい
        case keep
        case rewrite(QuestionRewrite)
        /// 質問が要らなくなった（理由つき）
        case drop(reason: String)
    }

    public struct Change: Equatable, Sendable {
        public var questions: QuestionsFile
        public var effects: [Effect]
    }

    /// 回答を受け付ける段階。開始の前まで（分け方の判断を待っている間も、答え直せば回答に戻る）
    static let answerableStages: Set<EpicStage> = [.asking, .checking, .awaitingSplit, .awaitingStart]
    /// 実装の途中の質問の答えを受け付ける段階（実装・最終 PR の段取り・人の確認の待ち）
    public static let implementationStages: Set<EpicStage> = [.running, .finalizing, .reviewing]
}

// MARK: - 質問を足す

extension QuestionFlow {
    /// 最初の質問づくりの結果から、質問の一覧を作る。依存先のある質問はロックして出す。
    /// 質問が 1 つも無ければ、そのまま着手前の確認に進む
    public static func start(_ drafts: [QuestionDraft]) throws(ResultError) -> Change {
        var book = try Book(QuestionsFile(questions: [])).adding(drafts, round: 1)
        book.checkReadiness()
        return book.change
    }

    /// 着手前の確認で出た追加の質問を足し、epic を回答に戻す。依存先がすべて決まっている質問は、そのまま回答を待つ
    public static func append(_ drafts: [QuestionDraft], round: Int, to file: QuestionsFile) throws(ResultError) -> Change {
        guard !drafts.isEmpty else { throw .invalid(["足す質問が無い"]) }
        guard round >= 2 else { throw .invalid(["追加の質問の round は 2 以上"]) }
        var book = try Book(file).adding(drafts, round: round)
        book.effects.append(.reopen)
        return book.change
    }

    /// 実装・直しの途中で Claude が聞いた質問を足す（`docs/renewal/flows.md` の「実装の途中の質問」）。
    /// `job` は質問したジョブ、`task` はどのタスクの途中か（最終 PR の直しは nil）。
    /// id は続きの `q<番号>`、`round` は最後の質問の `round` に 1 を足したもの（質問が無ければ 2）。依存先は持たず、すぐ回答を待つ。
    /// 同じジョブの質問がすでにあれば（前の周で足した）、そのまま返す
    public static func ask(
        _ asked: TaskOutputReport.Question,
        job: ULID,
        task: String?,
        in file: QuestionsFile
    ) throws(ResultError) -> QuestionsFile {
        guard !file.questions.contains(where: { $0.job == job }) else { return file }
        let number = (file.questions.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let round = (file.questions.map(\.round).max() ?? 1) + 1
        var book = Book(file)
        book.questions.append(.init(
            id: "q\(number)",
            title: asked.title,
            why: asked.why,
            options: asked.options,
            recommended: asked.recommended,
            reason: asked.reason,
            round: round,
            state: .open,
            job: job,
            task: task
        ))
        try book.validate()
        return book.change.questions
    }
}

// MARK: - 人の回答

extension QuestionFlow {
    /// 回答と、説明を求める、を受け付ける。署名・有効期間・使い済みかは、呼ぶ前に確かめておく
    public static func accept(
        _ answer: AnswerIntent,
        epic: EpicFile,
        questions file: QuestionsFile,
        at now: Timestamp
    ) throws(Rejection) -> Change {
        guard answer.repo == epic.repo, answer.epic == epic.id else { throw .otherEpic }
        if implementationStages.contains(epic.stage) { return try acceptDuringImplementation(answer, epic: epic, questions: file, at: now) }
        return try acceptBeforeStart(answer, epic: epic, questions: file, at: now)
    }

    /// 開始する前の回答と、説明を求める。答え直したら、依存する質問を見直しからやり直す
    private static func acceptBeforeStart(
        _ answer: AnswerIntent,
        epic: EpicFile,
        questions file: QuestionsFile,
        at now: Timestamp
    ) throws(Rejection) -> Change {
        guard answerableStages.contains(epic.stage) else { throw .notAcceptingAnswers(epic.stage) }
        var book = Book(file)
        guard let index = book.index(of: answer.question) else { throw .unknownQuestion(answer.question) }
        let question = book.questions[index]
        guard question.version == answer.questionVersion else {
            throw .staleVersion(question: question.id, current: question.version)
        }
        switch answer.mode {
        case .clarify:
            guard question.state == .open else { throw .notAnswerable(question: question.id, state: question.state) }
            book.questions[index].explanations.append(.init(asked: answer.intent, note: answer.note, at: now))
            book.questions[index].state = .clarifying
            book.effects.append(.explain(question: question.id, asked: answer.intent))
        case .answer:
            guard [.open, .answered].contains(question.state) else {
                throw .notAnswerable(question: question.id, state: question.state)
            }
            let accepted = try decision(answer, for: question, at: now)
            book.questions[index].answer = accepted
            book.questions[index].state = .answered
            // 開始の前に回答を変えたら、依存する質問の回答を取り消し、ロックに戻して見直しからやり直す
            if let previous = question.answer, !isSameDecision(previous, accepted) {
                book.relockDependents(of: question.id)
            }
            book.promote()
        }
        if epic.stage != .asking { book.effects.insert(.reopen, at: 0) }
        book.checkReadiness()
        return book.change
    }

    /// 開始した後の、実装の途中の質問への回答と、説明を求める。答えたら質問したジョブを再開する（答え直せない）。
    /// 依存先は持たないので、ほかの質問のロックと着手前の確認には触れない
    private static func acceptDuringImplementation(
        _ answer: AnswerIntent,
        epic: EpicFile,
        questions file: QuestionsFile,
        at now: Timestamp
    ) throws(Rejection) -> Change {
        var book = Book(file)
        // 開始する前の質問には、今までどおり答えられない
        guard let index = book.index(of: answer.question), let job = book.questions[index].job else {
            throw .notAcceptingAnswers(epic.stage)
        }
        let question = book.questions[index]
        guard question.version == answer.questionVersion else {
            throw .staleVersion(question: question.id, current: question.version)
        }
        if question.state == .answered { throw .resumed(question: question.id) }
        guard question.state == .open else { throw .notAnswerable(question: question.id, state: question.state) }
        switch answer.mode {
        case .clarify:
            book.questions[index].explanations.append(.init(asked: answer.intent, note: answer.note, at: now))
            book.questions[index].state = .clarifying
            book.effects.append(.explain(question: question.id, asked: answer.intent))
        case .answer:
            book.questions[index].answer = try decision(answer, for: question, at: now)
            book.questions[index].state = .answered
            book.effects.append(.resume(question: question.id, job: job))
        }
        return book.change
    }

    private static func decision(
        _ answer: AnswerIntent,
        for question: QuestionsFile.Question,
        at now: Timestamp
    ) throws(Rejection) -> QuestionsFile.Answer {
        if let choice = answer.choice, !question.options.contains(where: { $0.label == choice }) {
            throw .unknownChoice(question: question.id)
        }
        return .init(choice: answer.choice, note: answer.note, intent: answer.intent, at: now)
    }

    private static func isSameDecision(_ lhs: QuestionsFile.Answer, _ rhs: QuestionsFile.Answer) -> Bool {
        lhs.choice == rhs.choice && lhs.note == rhs.note
    }
}

// MARK: - Claude の結果

extension QuestionFlow {
    /// 説明を書く。書き直しの案があれば、質問の版を上げて書き直す。質問は回答を待つ状態に戻る
    public static func explain(
        _ id: String,
        asked: IntentReference,
        text: String,
        rewrite: QuestionRewrite?,
        in file: QuestionsFile
    ) throws(ResultError) -> Change {
        var book = Book(file)
        guard let index = book.index(of: id), book.questions[index].state == .clarifying,
              let last = book.questions[index].explanations.indices.last,
              book.questions[index].explanations[last].asked == asked, book.questions[index].explanations[last].text == nil else {
            throw .stale
        }
        guard !text.isEmpty else { throw .invalid(["説明が空"]) }
        var question = book.questions[index]
        question.explanations[last].text = text
        if let rewrite { question = try rewritten(question, with: rewrite, by: .explain) }
        question.state = .open
        book.questions[index] = question
        try book.validate()
        return book.change
    }

    /// 説明をやめる（説明のジョブを人がやめた）。説明を待つ問いを外し、質問は回答を待つ状態に戻る
    public static func abandonExplanation(_ id: String, asked: IntentReference, in file: QuestionsFile) throws(ResultError) -> Change {
        var book = Book(file)
        guard let index = book.index(of: id), book.questions[index].state == .clarifying,
              book.questions[index].explanations.last?.asked == asked, book.questions[index].explanations.last?.text == nil else {
            throw .stale
        }
        book.questions[index].explanations.removeLast()
        book.questions[index].state = .open
        try book.validate()
        return book.change
    }

    /// 見直しの結果を書く。要らなくなったら、その質問に依存する質問の見直しに進む
    public static func revise(
        _ id: String,
        basis: RevisionBasis,
        outcome: RevisionOutcome,
        in file: QuestionsFile
    ) throws(ResultError) -> Change {
        var book = Book(file)
        guard let index = book.index(of: id), book.questions[index].state == .revising,
              book.basis(of: book.questions[index]) == basis else {
            throw .stale
        }
        var question = book.questions[index]
        switch outcome {
        case .keep:
            question.state = .open
        case let .rewrite(rewrite):
            question = try rewritten(question, with: rewrite, by: .dependency)
            question.state = .open
        case let .drop(reason):
            guard !reason.isEmpty else { throw .invalid(["要らない理由が空"]) }
            question.revision = .init(from: question.version, reason: reason, by: .dependency)
            question.version += 1
            question.state = .dropped
        }
        book.questions[index] = question
        try book.validate()
        book.promote()
        book.checkReadiness()
        return book.change
    }

    private static func rewritten(
        _ question: QuestionsFile.Question,
        with rewrite: QuestionRewrite,
        by cause: QuestionsFile.RevisionCause
    ) throws(ResultError) -> QuestionsFile.Question {
        guard !rewrite.change.isEmpty else { throw .invalid(["書き直した理由が空"]) }
        var question = question
        question.revision = .init(from: question.version, reason: rewrite.change, by: cause)
        question.version += 1
        question.title = rewrite.title
        question.why = rewrite.why
        question.options = rewrite.options
        question.recommended = rewrite.recommended
        question.reason = rewrite.reason
        question.caution = rewrite.caution
        return question
    }
}
