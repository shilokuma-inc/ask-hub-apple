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

    /// 慎重に決めてほしい理由（質問と判断の確認だけ）
    var caution: Caution? {
        switch content {
        case .question(let question): question.caution
        case .decision(let decision): decision.caution
        case .verification: nil
        }
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
        /// 判断のカードの「直してほしい」（カードを見たときの head に結びつける）
        case decisionFix(epicID: Epic.ID, decisionID: DecisionCard.ID, headCommit: String?)
        /// 最終 PR への指示（見た head のコミットに結びつける）
        case finalInstruction(epicID: Epic.ID, headCommit: String)
        /// 実機確認の「問題あり」。`release` があれば「このリリースで直す」、nil なら次のリリースで直す
        case verificationProblem(epicID: Epic.ID, itemID: VerificationItem.ID, release: String? = nil)
        /// 実機確認の「確かめずに閉じる」（epic の残りの項目をまとめて閉じる理由。空でもよい）
        case closingVerifications(epicID: Epic.ID)
        case blockerInstruction(epicID: Epic.ID)
        case goalRevision(epicID: Epic.ID)
    }

    func intent(text: String) -> HumanIntent {
        switch purpose {
        case let .explanation(epicID, questionID):
            .requestExplanation(epicID: epicID, questionID: questionID, request: text)

        case let .freeTextAnswer(epicID, questionID):
            .answer(epicID: epicID, questionID: questionID, optionID: nil, note: text)

        case let .decisionFix(epicID, decisionID, headCommit):
            .respondToDecision(epicID: epicID, decisionID: decisionID, headCommit: headCommit, reply: .fix(text))

        case let .finalInstruction(epicID, headCommit):
            .instructFinal(epicID: epicID, headCommit: headCommit, instruction: text)

        case let .verificationProblem(epicID, itemID, release):
            .verify(epicID: epicID, itemID: itemID, reply: .problem(note: text, release: release))

        case .closingVerifications(let epicID):
            .closeVerifications(epicID: epicID, reply: .skipped(note: text))

        case .blockerInstruction(let epicID):
            .resolveBlocker(epicID: epicID, action: .fixWithInstruction, instruction: text)

        case .goalRevision(let epicID):
            .reviseGoal(epicID: epicID, request: text)
        }
    }
}

extension TextRequest {
    /// 実機確認の「確かめずに閉じる」の理由を書いてもらう（書かずに閉じてもよい）
    static func closingVerifications(epicID: Epic.ID) -> Self {
        TextRequest(title: "確かめずに閉じる", prompt: "閉じる理由（任意）", purpose: .closingVerifications(epicID: epicID), allowsEmpty: true)
    }
}

/// 状態から判断のカードを組み立てる
enum DeckBuilder {
    static func cards(from snapshot: ClientSnapshot, scope: DeckScope) -> [DeckCard] {
        switch scope {
        case .all:
            // 実機確認は入れない（手元に端末が要るので、あなたの番の「実機で確かめる」から一覧を開いて答える。2026-11-24 のユーザーの決定）
            let epics = snapshot.activeEpics.sorted { $0.updatedAt > $1.updatedAt }
            return epics.flatMap(questionCards) + epics.flatMap(decisionCards)

        case .questions(let id):
            return snapshot.epic(id).map(questionCards) ?? []

        case .decisions(let id):
            return snapshot.epic(id).map(decisionCards) ?? []

        case .verifications(let id):
            return snapshot.epic(id).map { verificationCards($0, release: snapshot.fixableRelease(of: $0.repositoryID)) } ?? []

        case .allVerifications:
            // 配信した版の確認（畳んだもの）は流さない。一覧から epic ごとに開けば答えられる
            return VerificationBacklog(snapshot: snapshot).open.flatMap { entry in
                verificationCards(entry.epic, release: snapshot.fixableRelease(of: entry.epic.repositoryID))
            }
        }
    }

    /// 開始する前の質問と、実装の途中の質問（同じカードで出し、実装の途中の質問であることを札の種類に添える）
    static func questionCards(_ epic: Epic) -> [DeckCard] {
        epic.awaitedQuestions.map { question in
            DeckCard(
                id: "\(epic.id)/question/\(question.id)",
                epicID: epic.id,
                repositoryID: epic.repositoryID,
                content: .question(question),
                kindLabel: question.during == nil ? "質問 \(question.id) / \(epic.questions.count)" : "実装の途中の質問 \(question.id)",
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
                choices: decisionChoices(decision, epicID: epic.id, headCommit: review.headCommit)
            )
        }
    }

    /// OK を先頭（推奨）にし、直してほしい・別案（最大 2 つ）を続ける。直してほしい（自由回答）は OK の対角に置く。
    /// 答えは、カードを組み立てたときの最終 PR の head に結びつける
    static func decisionChoices(_ decision: DecisionCard, epicID: Epic.ID, headCommit: String?) -> [DeckCard.Choice] {
        var choices = [
            DeckCard.Choice(
                id: "accept",
                label: "OK",
                detail: "このままにする",
                note: nil,
                isRecommended: true,
                action: .send(.respondToDecision(epicID: epicID, decisionID: decision.id, headCommit: headCommit, reply: .accept))
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
                    purpose: .decisionFix(epicID: epicID, decisionID: decision.id, headCommit: headCommit)
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
                action: .send(.respondToDecision(
                    epicID: epicID,
                    decisionID: decision.id,
                    headCommit: headCommit,
                    reply: .alternative(alternative)
                ))
            ))
        }
        return SwipeLayout.arranged(choices, asksText: \.asksText)
    }

    /// 実機確認のカード。`release` はリポジトリの進行中のリリース（「このリリースを直す」依頼を出せるもの）。あれば「問題あり」を
    /// 「このリリースで直す」と「次のリリースで直す」に分け、既定（推奨の対角に置く方）を、epic がその release ブランチを作る前に
    /// マージされていれば「このリリース」、後なら「次のリリース」にする（2026-11-22 のユーザーの決定）
    static func verificationCards(_ epic: Epic, release: Submission? = nil) -> [DeckCard] {
        let items = epic.finalReview?.verifications.filter(\.isReady) ?? []
        return items.map { item in
            var build: String?
            if case .ready(let value) = item.state {
                build = value
            }
            return DeckCard(
                id: "\(epic.id)/verification/\(item.id)",
                epicID: epic.id,
                repositoryID: epic.repositoryID,
                content: .verification(item),
                kindLabel: "実機で確かめる · \(VerificationItem.buildLabel(build))",
                title: item.text,
                // 状態リポジトリの項目（ゴールの完了の条件）には手順が無い
                detail: item.steps.isEmpty ? "TestFlight に上がった版を入れて、この条件を満たすか確かめてください" : "手順: \(item.steps)",
                choices: SwipeLayout.arranged(
                    [
                        DeckCard.Choice(
                            id: "confirmed",
                            label: "確認した",
                            detail: "問題なく動いた",
                            note: nil,
                            isRecommended: true,
                            action: .send(.verify(epicID: epic.id, itemID: item.id, reply: .confirmed))
                        )
                    ] + problemChoices(epic, item: item, release: release),
                    asksText: \.asksText
                )
            )
        }
    }

    /// 実機確認の「問題あり」。進行中のリリースが無ければ 1 つ（次のリリースで直す）。あれば既定を先に、2 つに分ける
    private static func problemChoices(_ epic: Epic, item: VerificationItem, release: Submission?) -> [DeckCard.Choice] {
        func choice(_ id: String, label: String, detail: String, title: String, release: String?) -> DeckCard.Choice {
            DeckCard.Choice(
                id: id,
                label: label,
                detail: detail,
                note: nil,
                isRecommended: false,
                action: .askText(TextRequest(
                    title: title,
                    prompt: "何が起きたか",
                    purpose: .verificationProblem(epicID: epic.id, itemID: item.id, release: release)
                ))
            )
        }
        guard let release else {
            return [choice("problem", label: "問題あり", detail: "内容を書いて新しい依頼にする", title: "問題あり", release: nil)]
        }
        let thisRelease = choice(
            "problem.release",
            label: "問題あり・このリリースで直す",
            detail: "\(release.version) の release ブランチに直しを入れる",
            title: "問題あり（\(release.version) で直す）",
            release: release.version
        )
        let nextRelease = choice(
            "problem",
            label: "問題あり・次のリリースで直す",
            detail: "develop に直しを入れ、次のリリースで出す",
            title: "問題あり（次のリリースで直す）",
            release: nil
        )
        return isIncluded(epic, in: release) ? [thisRelease, nextRelease] : [nextRelease, thisRelease]
    }

    /// epic が、リリースの release ブランチを作る前にマージされていた（そのリリースに入っている）か。分からなければ false
    static func isIncluded(_ epic: Epic, in release: Submission) -> Bool {
        guard let branchCreatedAt = release.branchCreatedAt, case let .merged(mergedAt, _)? = epic.finalReview?.state else {
            return false
        }
        return mergedAt <= branchCreatedAt
    }
}
