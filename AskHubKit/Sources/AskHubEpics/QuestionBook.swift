import AskHubProtocol
import Foundation

extension QuestionFlow {
    /// 質問の一覧を書き換えながら、司令塔がすることを集める
    struct Book {
        var questions: [QuestionsFile.Question]
        var effects: [Effect] = []

        init(_ file: QuestionsFile) {
            questions = file.questions
        }

        var change: Change { Change(questions: QuestionsFile(questions: questions), effects: effects) }

        func index(of id: String) -> Int? {
            questions.firstIndex { $0.id == id }
        }

        /// 決まりに合わなければ、合わない点を返す（Claude に直させる）
        func validate() throws(ResultError) {
            let violations = QuestionsFile(questions: questions).violations
            guard violations.isEmpty else { throw .invalid(violations) }
        }

        /// 質問の案を足す。依存先がすべて決まっていれば回答を待ち、そうでなければロックする。
        /// 案は依存先の回答を知って作られるので、決まった依存先だけを持つ案は見直さない
        func adding(_ drafts: [QuestionDraft], round: Int) throws(ResultError) -> Self {
            let existing = Set(questions.map(\.id))
            let duplicates = drafts.map(\.id).filter(existing.contains)
            guard duplicates.isEmpty else { throw .invalid(["すでにある質問の id: \(duplicates.joined(separator: "・"))"]) }
            let settled = Set(questions.filter(\.state.isSettled).map(\.id))
            var book = self
            for draft in drafts {
                book.questions.append(.init(
                    id: draft.id,
                    title: draft.title,
                    why: draft.why,
                    options: draft.options,
                    recommended: draft.recommended,
                    reason: draft.reason,
                    caution: draft.caution,
                    dependsOn: draft.dependsOn,
                    round: round,
                    state: draft.dependsOn.allSatisfy(settled.contains) ? .open : .locked
                ))
            }
            try book.validate()
            return book
        }

        /// 見直しを頼むときの、質問と依存先の版と回答
        func basis(of question: QuestionsFile.Question) -> RevisionBasis {
            let dependencies = question.dependsOn.compactMap { id in
                index(of: id).map { questions[$0] }.map { RevisionBasis.Dependency(id: id, version: $0.version, answer: $0.answer?.intent) }
            }
            return RevisionBasis(version: question.version, dependencies: dependencies)
        }

        /// その質問に（間接にも）依存する質問を、すべてロックに戻す。回答・説明待ちの問いは取り消す
        mutating func relockDependents(of id: String) {
            var queue = QuestionsFile(questions: questions).dependents(of: id)
            var seen: Set<String> = []
            var cursor = 0
            while cursor < queue.count {
                let next = queue[cursor]
                cursor += 1
                guard seen.insert(next).inserted, let index = index(of: next) else { continue }
                relock(at: index)
                queue += QuestionsFile(questions: questions).dependents(of: next)
            }
        }

        private mutating func relock(at index: Int) {
            var question = questions[index]
            switch question.state {
            case .locked:
                return
            case .clarifying:
                effects.append(.cancel(question: question.id))
                question.explanations.removeLast()
            case .revising:
                effects.append(.cancel(question: question.id))
            case .dropped:
                // 要らなくなったのは前の回答を受けた見直しの結果なので、理由を消して見直し直す
                question.revision = nil
            case .open, .answered, .delegated:
                break
            }
            question.answer = nil
            question.state = .locked
            questions[index] = question
        }

        /// 依存先がすべて決まったロックの質問を、見直しに進める
        mutating func promote() {
            let settled = Set(questions.filter(\.state.isSettled).map(\.id))
            let ready = questions.indices.filter { questions[$0].state == .locked && questions[$0].dependsOn.allSatisfy(settled.contains) }
            for index in ready {
                questions[index].state = .revising
                effects.append(.revise(question: questions[index].id, basis: basis(of: questions[index])))
            }
        }

        /// すべての質問が決まったら、着手前の確認に進める
        mutating func checkReadiness() {
            if questions.allSatisfy(\.state.isSettled) { effects.append(.checkReadiness) }
        }
    }
}
