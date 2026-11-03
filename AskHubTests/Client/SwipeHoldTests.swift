@testable import AskHub
import CoreGraphics
import Foundation
import Testing

/// 自由回答（送る前に文を書く選択肢）は、カードを飛ばさずにその方向で止めてシートを出し、送ったら飛ばし、閉じたら戻す
@MainActor
struct SwipeHoldTests {
    private let snapshot = DemoScenario.standard.snapshot(now: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: 止める選択肢

    /// 送る前に文を書く選択肢だけを止める
    @Test
    func holdsOnlyChoicesThatAskForText() {
        let request = TextRequest(title: "直してほしい", prompt: "どう直してほしいか", purpose: .goalRevision(epicID: "e"))
        let choices = [
            choice("accept", action: .send(.delegate(epicID: "e", questionID: "Q1"))),
            choice("fix", action: .askText(request)),
            choice("other", action: .send(.delegate(epicID: "e", questionID: "Q2")))
        ]
        #expect(SwipeHold.heldChoices(choices) == [1])
        #expect(SwipeHold.heldChoices([]).isEmpty)
    }

    /// 判断の「直してほしい」と実機確認の「問題あり」を止め、OK・別案・確認したは飛ばす
    @Test(arguments: [
        (DeckScope.decisions("tsundoku-search"), "fix"),
        (DeckScope.verifications("habit-review"), "problem")
    ])
    func holdsFixAndProblem(scope: DeckScope, heldID: String) {
        let cards = DeckBuilder.cards(from: snapshot, scope: scope)
        #expect(!cards.isEmpty)
        for card in cards {
            let held = SwipeHold.heldChoices(card.choices).map { card.choices[$0].id }
            #expect(held == [heldID])
        }
    }

    /// 質問の選択肢（書かれた答え）は止めない
    @Test
    func doesNotHoldQuestionOptions() throws {
        let card = try #require(DeckBuilder.cards(from: snapshot, scope: .questions("habit-export")).first { !$0.choices.isEmpty })
        guard case .question(let question) = card.content else {
            Issue.record("質問のカードではない")
            return
        }
        let held = SwipeHold.heldChoices(card.choices).map { card.choices[$0].id }
        #expect(Set(held).isDisjoint(with: question.options.map(\.id)))
    }

    // MARK: 止める位置

    /// その方向へ、ちょうど決まる距離だけ動かした所で止める。止めた所は、その方向の選択肢を指したままになる
    @Test(arguments: [Handedness.right, .left], 2...4)
    func holdsAtCommitDistanceTowardChoice(hand: Handedness, count: Int) {
        let directions = SwipeLayout.directions(count: count, hand: hand)
        for (index, direction) in directions.enumerated() {
            let offset = SwipeHold.offset(for: direction)
            #expect(abs(hypot(offset.width, offset.height) - SwipeLayout.commitDistance) < 0.001)
            #expect(SwipeLayout.candidate(for: offset, directions: directions) == index)
        }
    }

    // MARK: シートを出してから

    /// シートで送ったら、シートが閉じてからカードを飛ばし、飛び終わったら書いた文を渡す
    @Test
    func fliesAfterSheetClosesThenHandsOverText() {
        var hold = SwipeHold()
        hold.start()
        let held = hold.send("並び順を逆にしてほしい")
        #expect(held)
        // シートが閉じるまでは飛ばさない
        #expect(hold.releaseToken == 0)
        let returnsCard = hold.sheetDismissed()
        #expect(!returnsCard)
        #expect(hold.releaseToken == 1)
        let text = hold.finish()
        #expect(text == "並び順を逆にしてほしい")
        // 2 度は送らない
        let again = hold.finish()
        #expect(again == nil)
    }

    /// 送らずに閉じたら（キャンセル・下へ払う）、飛ばさずに元の位置に戻す
    @Test
    func returnsCardWhenClosedWithoutSending() {
        var hold = SwipeHold()
        hold.start()
        let returnsCard = hold.sheetDismissed()
        #expect(returnsCard)
        #expect(hold.releaseToken == 0)
        let text = hold.finish()
        #expect(text == nil)
        // 戻した後にもう一度閉じても、何もしない
        let returnsAgain = hold.sheetDismissed()
        #expect(!returnsAgain)
    }

    /// 止めていないとき（説明を求めるなど）に送った文は、その場で送る
    @Test
    func sendsRightAwayWithoutHolding() {
        var hold = SwipeHold()
        let held = hold.send("どういう意味？")
        #expect(!held)
        let returnsCard = hold.sheetDismissed()
        #expect(!returnsCard)
        #expect(hold.releaseToken == 0)
        let text = hold.finish()
        #expect(text == nil)
    }

    /// 戻した後に、もう一度止めて送れる
    @Test
    func holdsAgainAfterReturning() {
        var hold = SwipeHold()
        hold.start()
        _ = hold.sheetDismissed()
        hold.start()
        _ = hold.send("2 回目")
        _ = hold.sheetDismissed()
        #expect(hold.releaseToken == 1)
        let text = hold.finish()
        #expect(text == "2 回目")
    }

    private func choice(_ id: String, action: DeckCard.Action) -> DeckCard.Choice {
        DeckCard.Choice(id: id, label: id, detail: "", note: nil, isRecommended: false, action: action)
    }
}
