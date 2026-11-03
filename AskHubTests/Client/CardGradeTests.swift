@testable import AskHub
import Foundation
import Testing

/// 札の格。表に返るときの演出の強さと色が、札の中身だけで決まる
@MainActor
struct CardGradeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var snapshot: ClientSnapshot { DemoScenario.standard.snapshot(now: now) }

    private func grade(
        _ cardID: String,
        scope: DeckScope = .all,
        answered: Set<String> = [],
        in snapshot: ClientSnapshot? = nil
    ) throws -> CardGrade {
        let snapshot = snapshot ?? self.snapshot
        let remaining = DeckBuilder.cards(from: snapshot, scope: scope).filter { !answered.contains($0.id) }
        let card = try #require(remaining.first { $0.id == cardID })
        return CardGrade(card: card, epic: snapshot.epic(card.epicID), remaining: remaining)
    }

    /// ほかの質問（ロック中）がこの回答を待っていれば、先へ進める札
    @Test
    func questionAwaitedByLockedQuestionsIsKey() throws {
        #expect(try grade("recipe-weekly/question/Q3") == .key)
    }

    /// 同じ epic の答えられる質問がほかに残っていれば、ふつう
    @Test
    func questionWithSiblingsIsCommon() throws {
        #expect(try grade("habit-export/question/Q3") == .common)
    }

    /// ほかの質問を答え終えた（取り消しを待っている・飛び始めた）なら、最後の 1 枚として先へ進める札
    @Test
    func lastQuestionIsKey() throws {
        let answered: Set = ["habit-export/question/Q2", "habit-export/question/Q3"]
        #expect(try grade("habit-export/question/Q4", answered: answered) == .key)
    }

    /// 判断の確認は、最後の 1 枚だけが先へ進める札
    @Test
    func onlyLastDecisionIsKey() throws {
        let scope = DeckScope.decisions("tsundoku-search")
        #expect(try grade("tsundoku-search/decision/d3", scope: scope) == .common)
        let answered: Set = ["tsundoku-search/decision/d3", "tsundoku-search/decision/d4"]
        #expect(try grade("tsundoku-search/decision/d5", scope: scope, answered: answered) == .key)
    }

    /// 実機の確認はいつも実機の格（最後の 1 枚でも先へ進める札にしない）
    @Test
    func verificationIsDevice() throws {
        let scope = DeckScope.verifications("habit-review")
        #expect(try grade("habit-review/verification/habit-v1", scope: scope) == .device)
        #expect(try grade("habit-review/verification/habit-v2", scope: scope, answered: ["habit-review/verification/habit-v1"]) == .device)
    }

    /// デモの「書き出したファイルの置き場所」は、セキュリティの警告
    @Test
    func cautionedQuestionIsCaution() throws {
        #expect(try grade("habit-export/question/Q2") == .caution(.security))
    }

    /// 警告は、先へ進める札（最後の 1 枚）よりも先に決める
    @Test
    func cautionWinsOverKey() throws {
        var snapshot = snapshot
        snapshot.updateEpic("habit-export") { epic in
            if let index = epic.questions.firstIndex(where: { $0.id == "Q4" }) {
                epic.questions[index].caution = .irreversible
            }
        }
        let answered: Set = ["habit-export/question/Q2", "habit-export/question/Q3"]
        #expect(try grade("habit-export/question/Q4", answered: answered, in: snapshot) == .caution(.irreversible))
    }

    /// ふつうの札は溜めない・先へ進める札と実機は持ち上げて溜める・警告は持ち上げずに揺れる
    @Test
    func chargeStyleDependsOnGrade() {
        #expect(CardGrade.common.chargeStyle == .none)
        #expect(CardGrade.device.chargeStyle == .lift)
        #expect(CardGrade.key.chargeStyle == .lift)
        #expect(CardGrade.caution(.security).chargeStyle == .alert)
    }
}
