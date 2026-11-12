@testable import AskHub
import Foundation
import Testing

/// 状態から画面の一覧（あなたの番・判断のカード・epic のいま）を組み立てる処理
@MainActor
struct BuilderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var snapshot: ClientSnapshot { DemoScenario.standard.snapshot(now: now) }

    // MARK: あなたの番

    /// 進行を止めるものと止めないものに分ける
    @Test
    func splitsBlockingAndWhenFree() {
        let items = InboxBuilder.items(from: snapshot, now: now)
        let blocking = Set(items.filter { $0.urgency == .blocking }.map(\.kind))
        let whenFree = Set(items.filter { $0.urgency == .whenFree }.map(\.kind))
        #expect(blocking == [.questions, .goal, .humanTask, .blocker, .macOffline])
        #expect(whenFree == [.finalReview, .verification, .cleanup, .token, .claudeVersion, .repositorySetup])
    }

    /// 急ぎを先に新しい順に並べる
    @Test
    func sortsBlockingFirstNewestFirst() {
        let items = InboxBuilder.items(from: snapshot, now: now)
        let firstWhenFree = items.firstIndex { $0.urgency == .whenFree } ?? items.count
        #expect(items[..<firstWhenFree].allSatisfy { $0.urgency == .blocking })
        let blockingDates = items[..<firstWhenFree].map(\.since)
        #expect(blockingDates == blockingDates.sorted(by: >))
    }

    /// 閉じたばかりの Mac は知らせない
    @Test
    func ignoresRecentlyClosedMac() {
        var snapshot = snapshot
        snapshot.updateMac(DemoData.macBookAirID) { $0.connection = .offline(since: now.addingTimeInterval(-60)) }
        let kinds = InboxBuilder.items(from: snapshot, now: now).map(\.kind)
        #expect(!kinds.contains(.macOffline))
    }

    /// 質問の行に説明待ちとロックの数を出す
    @Test
    func questionRowCountsExplainingAndLocked() throws {
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.id == "recipe-weekly/questions" })
        #expect(item.detail == "残り 1 問 · 説明待ち 1 · ロック 2")
        #expect(item.route == .deck(.questions("recipe-weekly")))
    }

    /// 自動でマージする最終 PR は出さない
    @Test
    func hidesAutomaticallyMergedFinalReview() {
        var snapshot = snapshot
        snapshot.updateEpic("tsundoku-search") { $0.finalReview?.mergePolicy = .automatic }
        let kinds = InboxBuilder.items(from: snapshot, now: now).map(\.kind)
        #expect(!kinds.contains(.finalReview))
    }

    // MARK: 判断のカード

    /// 質問のカードは推奨の選択肢を先頭にする
    @Test
    func questionCardPutsRecommendedFirst() throws {
        let cards = DeckBuilder.cards(from: snapshot, scope: .questions("recipe-weekly"))
        let card = try #require(cards.first)
        #expect(cards.map(\.id) == ["recipe-weekly/question/Q3"])
        #expect(card.choices.first?.label == "月曜の朝 9 時に固定")
        #expect(card.choices.first?.isRecommended == true)
        #expect(card.choices.map(\.label) == ["月曜の朝 9 時に固定", "曜日と時刻を選べる", "日曜の夜 8 時に固定"])
    }

    /// 判断のカードは OK を先頭にし別案は 2 つまで。直してほしい（自由回答）は OK の対角の位置に置く
    @Test
    func decisionCardPutsAcceptFirstWithTwoAlternatives() throws {
        let cards = DeckBuilder.cards(from: snapshot, scope: .decisions("tsundoku-search"))
        #expect(cards.map(\.id) == ["tsundoku-search/decision/d3", "tsundoku-search/decision/d4", "tsundoku-search/decision/d5"])
        let first = try #require(cards.first)
        #expect(first.choices.map(\.id) == ["accept", "alternative-0", "fix", "alternative-1"])
        #expect(first.choices.first?.isRecommended == true)
        // 別案が 1 つ（3 択）と無い（2 択）カード
        #expect(cards[1].choices.map(\.id) == ["accept", "alternative-0", "fix"])
        #expect(cards[2].choices.map(\.id) == ["accept", "fix"])
    }

    /// どのカードでも、自由回答の選択肢は推奨の対角（右手は ↙・左手は ↘）にあり、「自由回答」の札が付く
    @Test
    func freeTextChoicesSitOppositeRecommended() throws {
        let cards = DeckBuilder.cards(from: snapshot, scope: .all)
        let withFreeText = cards.filter { $0.choices.contains(where: \.asksText) }
        // 判断の確認（直してほしい）と実機確認（問題あり）。質問の選択肢には自由回答が無い
        let kinds = Set(withFreeText.map { card in
            switch card.content {
            case .question: "question"
            case .decision: "decision"
            case .verification: "verification"
            }
        })
        #expect(kinds == ["decision", "verification"])
        for card in withFreeText {
            let index = try #require(card.choices.firstIndex { $0.asksText })
            #expect(card.choices.first?.isRecommended == true)
            #expect(SwipeLayout.directions(count: card.choices.count, hand: .right)[index] == .downLeft)
            #expect(SwipeLayout.directions(count: card.choices.count, hand: .left)[index] == .downRight)
        }
    }

    /// 読み上げでも札（推奨・自由回答）と方向が分かる
    @Test
    func choiceAccessibilityLabelIncludesBadges() throws {
        let card = try #require(DeckBuilder.cards(from: snapshot, scope: .decisions("tsundoku-search")).first)
        let labels = card.choices.enumerated().map { index, choice in
            DeckCardContent.accessibilityLabel(
                of: choice,
                direction: SwipeLayout.directions(count: card.choices.count, hand: .right)[index]
            )
        }
        #expect(labels == [
            "OK（推奨・右上へスワイプ）",
            "別案にする（左上へスワイプ）",
            "直してほしい（自由回答・左下へスワイプ）",
            "別案にする（右下へスワイプ）"
        ])
    }

    /// 実機確認のカードは確認したを先頭にする
    @Test
    func verificationCardPutsConfirmedFirst() {
        let cards = DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review"))
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.choices.map(\.id) == ["confirmed", "problem"] })
    }

    /// まとめて判断するはアプリをまたいで流す
    @Test
    func allScopeSpansApps() {
        let cards = DeckBuilder.cards(from: snapshot, scope: .all)
        #expect(Set(cards.map(\.repositoryID)).count >= 3)
        #expect(cards.count == 9)
    }

    // MARK: epic のいま

    /// 失敗で止まっている epic はあなた待ちになる
    @Test
    func blockedEpicWaitsForYou() throws {
        let epic = try #require(snapshot.epic("rain-draft"))
        let lines = EpicStatus.lines(for: epic, in: snapshot, now: now)
        #expect(lines.first?.owner == .you)
        #expect(lines.first?.text == "対処が要ります: ビルドが通りません")
        #expect(EpicStatus.waitsForYou(epic))
    }

    /// 機械だけが進めている epic はあなた待ちにしない
    @Test
    func machineOnlyEpicDoesNotWaitForYou() throws {
        let quiet = DemoScenario.quiet.snapshot(now: now)
        let epic = try #require(quiet.epic("kaji-notify"))
        #expect(!EpicStatus.waitsForYou(epic))
        #expect(EpicStatus.lines(for: epic, in: quiet, now: now).allSatisfy { $0.owner == .machine })
    }

    // MARK: マージの条件

    /// 判断を全部確かめるまでマージできない
    @Test
    func cannotMergeUntilAllDecisionsConfirmed() throws {
        var review = try #require(snapshot.epic("tsundoku-search")?.finalReview)
        review.checks.ci = .passed
        #expect(!review.canMerge)
        for index in review.decisions.indices {
            review.decisions[index].response = .accepted
        }
        #expect(review.canMerge)
    }

    /// 確かめた後に push されたらマージできない
    @Test
    func cannotMergeAfterPushFollowingReview() throws {
        var review = try #require(snapshot.epic("tsundoku-search")?.finalReview)
        review.checks.ci = .passed
        for index in review.decisions.indices {
            review.decisions[index].response = .accepted
        }
        review.reviewedHeadCommit = "0000000"
        #expect(review.headChangedAfterReview)
        #expect(!review.canMerge)
    }

    /// CI を通るまでマージできない
    @Test
    func cannotMergeUntilCIPasses() throws {
        var review = try #require(snapshot.epic("tsundoku-search")?.finalReview)
        for index in review.decisions.indices {
            review.decisions[index].response = .accepted
        }
        #expect(!review.canMerge)
    }
}
