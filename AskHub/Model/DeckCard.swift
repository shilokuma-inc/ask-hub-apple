import Foundation

/// 判断のカード（スワイプで選ぶ 1 枚）。質問・最終 PR の判断・実機確認を同じ形で流す
struct DeckCard: Identifiable, Hashable {
    let id: String
    var epicID: Epic.ID
    var repositoryID: TargetRepository.ID
    var content: Content
    /// 例: 質問 Q3 / 6
    var kindLabel: String
    var title: String
    var detail: String
    /// 選択肢。先頭は推奨（右手なら ↗ に置く）。空なら自由記述で答える
    var choices: [Choice]

    enum Content: Hashable {
        case question(Question)
        case decision(DecisionCard)
        case verification(VerificationItem)
    }

    struct Choice: Identifiable, Hashable {
        let id: String
        var label: String
        var detail: String
        /// 推奨の理由など、選択肢の下に出す補足
        var note: String?
        var isRecommended: Bool
        var action: Action

        /// 自由回答（送る前に文を書く）の選択肢か。推奨の対角に置き、「自由回答」の札を付ける
        var asksText: Bool {
            if case .askText = action {
                return true
            }
            return false
        }
    }

    enum Action: Hashable {
        case send(HumanIntent)
        /// 送る前に文を書いてもらう（直してほしい内容・問題の内容など）
        case askText(TextRequest)
    }
}

/// 送る前に書いてもらう文
struct TextRequest: Hashable {
    var title: String
    var prompt: String
    var purpose: Purpose
    /// 空のまま送ってよいか
    var allowsEmpty = false

    enum Purpose: Hashable {
        case explanation(epicID: Epic.ID, questionID: Question.ID)
        case freeTextAnswer(epicID: Epic.ID, questionID: Question.ID)
        case decisionFix(epicID: Epic.ID, decisionID: DecisionCard.ID)
        case verificationProblem(epicID: Epic.ID, itemID: VerificationItem.ID)
        case blockerInstruction(epicID: Epic.ID)
        case goalRevision(epicID: Epic.ID)
    }

    func intent(text: String) -> HumanIntent {
        switch purpose {
        case let .explanation(epicID, questionID):
            .requestExplanation(epicID: epicID, questionID: questionID, request: text)

        case let .freeTextAnswer(epicID, questionID):
            .answer(epicID: epicID, questionID: questionID, optionID: nil, note: text)

        case let .decisionFix(epicID, decisionID):
            .respondToDecision(epicID: epicID, decisionID: decisionID, reply: .fix(text))

        case let .verificationProblem(epicID, itemID):
            .verify(epicID: epicID, itemID: itemID, reply: .problem(note: text))

        case .blockerInstruction(let epicID):
            .resolveBlocker(epicID: epicID, action: .fixWithInstruction, instruction: text)

        case .goalRevision(let epicID):
            .reviseGoal(epicID: epicID, request: text)
        }
    }
}

/// 状態から判断のカードを組み立てる
enum DeckBuilder {
    static func cards(from snapshot: ClientSnapshot, scope: DeckScope) -> [DeckCard] {
        switch scope {
        case .all:
            let epics = snapshot.activeEpics.sorted { $0.updatedAt > $1.updatedAt }
            return epics.flatMap(questionCards)
                + epics.flatMap(decisionCards)
                + snapshot.epics.flatMap(verificationCards)

        case .questions(let id):
            return snapshot.epic(id).map(questionCards) ?? []

        case .decisions(let id):
            return snapshot.epic(id).map(decisionCards) ?? []

        case .verifications(let id):
            return snapshot.epic(id).map(verificationCards) ?? []
        }
    }

    static func questionCards(_ epic: Epic) -> [DeckCard] {
        guard epic.stage == .questions else {
            return []
        }
        return epic.answerableQuestions.map { question in
            DeckCard(
                id: "\(epic.id)/question/\(question.id)",
                epicID: epic.id,
                repositoryID: epic.repositoryID,
                content: .question(question),
                kindLabel: "質問 \(question.id) / \(epic.questions.count)",
                title: question.title,
                detail: question.why,
                choices: questionChoices(question, epicID: epic.id)
            )
        }
    }

    /// 推奨の選択肢を先頭にし、残りは書かれた順に並べる
    static func questionChoices(_ question: Question, epicID: Epic.ID) -> [DeckCard.Choice] {
        let recommended = question.options.filter { $0.id == question.recommendedOptionID }
        let others = question.options.filter { $0.id != question.recommendedOptionID }
        let choices = (recommended + others).map { option in
            let isRecommended = option.id == question.recommendedOptionID
            return DeckCard.Choice(
                id: option.id,
                label: option.label,
                detail: option.effect,
                note: isRecommended ? question.recommendationReason.map { "推奨の理由: \($0)" } : nil,
                isRecommended: isRecommended,
                action: .send(.answer(epicID: epicID, questionID: question.id, optionID: option.id, note: ""))
            )
        }
        return SwipeLayout.arranged(choices, asksText: \.asksText)
    }

    static func decisionCards(_ epic: Epic) -> [DeckCard] {
        guard let review = epic.finalReview, review.state == .reviewable else {
            return []
        }
        let total = review.decisions.count
        return review.pendingDecisions.map { decision in
            let number = (review.decisions.firstIndex(of: decision) ?? 0) + 1
            return DeckCard(
                id: "\(epic.id)/decision/\(decision.id)",
                epicID: epic.id,
                repositoryID: epic.repositoryID,
                content: .decision(decision),
                kindLabel: "判断の確認 \(number) / \(total)",
                title: decision.title,
                detail: "理由: \(decision.reason)",
                choices: decisionChoices(decision, epicID: epic.id)
            )
        }
    }

    /// OK を先頭（推奨）にし、直してほしい・別案（最大 2 つ）を続ける。直してほしい（自由回答）は OK の対角に置く
    static func decisionChoices(_ decision: DecisionCard, epicID: Epic.ID) -> [DeckCard.Choice] {
        var choices = [
            DeckCard.Choice(
                id: "accept",
                label: "OK",
                detail: "このままにする",
                note: nil,
                isRecommended: true,
                action: .send(.respondToDecision(epicID: epicID, decisionID: decision.id, reply: .accept))
            ),
            DeckCard.Choice(
                id: "fix",
                label: "直してほしい",
                detail: "指示を書いてループに戻す",
                note: nil,
                isRecommended: false,
                action: .askText(TextRequest(
                    title: "直してほしい",
                    prompt: "どう直してほしいか",
                    purpose: .decisionFix(epicID: epicID, decisionID: decision.id)
                ))
            )
        ]
        for (index, alternative) in decision.alternatives.prefix(2).enumerated() {
            choices.append(DeckCard.Choice(
                id: "alternative-\(index)",
                label: "別案にする",
                detail: alternative,
                note: nil,
                isRecommended: false,
                action: .send(.respondToDecision(epicID: epicID, decisionID: decision.id, reply: .alternative(alternative)))
            ))
        }
        return SwipeLayout.arranged(choices, asksText: \.asksText)
    }

    static func verificationCards(_ epic: Epic) -> [DeckCard] {
        let items = epic.finalReview?.verifications.filter(\.isReady) ?? []
        return items.map { item in
            var build = ""
            if case .ready(let value) = item.state {
                build = value
            }
            return DeckCard(
                id: "\(epic.id)/verification/\(item.id)",
                epicID: epic.id,
                repositoryID: epic.repositoryID,
                content: .verification(item),
                kindLabel: "実機で確かめる · TestFlight \(build)",
                title: item.text,
                detail: "手順: \(item.steps)",
                choices: [
                    DeckCard.Choice(
                        id: "confirmed",
                        label: "確認した",
                        detail: "問題なく動いた",
                        note: nil,
                        isRecommended: true,
                        action: .send(.verify(epicID: epic.id, itemID: item.id, reply: .confirmed))
                    ),
                    DeckCard.Choice(
                        id: "problem",
                        label: "問題あり",
                        detail: "内容を書いて新しい依頼にする",
                        note: nil,
                        isRecommended: false,
                        action: .askText(TextRequest(
                            title: "問題あり",
                            prompt: "何が起きたか",
                            purpose: .verificationProblem(epicID: epic.id, itemID: item.id)
                        ))
                    )
                ]
            )
        }
    }
}
