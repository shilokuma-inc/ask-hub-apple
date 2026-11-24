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
        // 習慣ログの 1.4.0 は審査で断られ、直し方を選ぶのを待っている
        #expect(blocking == [
            .questions, .goal, .humanTask, .blocker, .macOffline, .releaseNotes, .submissionReady, .submissionRejected, .appStoreSetup
        ])
        // 積読リストの app-kit のずれと、習慣ログのヘッダーと検索結果の案を確かめる番
        #expect(whenFree == [.finalReview, .verification, .cleanup, .token, .claudeVersion, .repositorySetup, .appKit, .creative])
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

    /// 見直している質問は、ロックと分けて数える
    @Test
    func questionRowCountsRevisingApartFromLocked() throws {
        var snapshot = snapshot
        snapshot.updateEpic("recipe-weekly") { $0.updateQuestion("Q5") { $0.state = .reviewing } }
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.id == "recipe-weekly/questions" })
        #expect(item.detail == "残り 1 問 · 説明待ち 1 · 見直し中 1 · ロック 1")
    }

    /// 答えられる質問が残っていなくても、見直している質問があれば、消えたように見せずに時間のあるときの行で出す
    @Test
    func epicWithOnlyRevisingQuestionsStaysWhenFree() throws {
        var snapshot = snapshot
        let answered = Question.State.answered(Question.Response(optionID: "a", note: "", answeredAt: now))
        snapshot.updateEpic("recipe-weekly") { epic in
            epic.updateQuestion("Q3") { $0.state = answered }
            epic.updateQuestion("Q4") { $0.state = answered }
            epic.updateQuestion("Q5") { $0.state = .reviewing }
        }
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.id == "recipe-weekly/questions" })
        #expect(item.urgency == .whenFree)
        #expect(item.title == "質問の見直しを待っています")
        #expect(item.detail == "Claude が Q5 を見直しています。終わったら答えられます")
        #expect(item.route == .epic("recipe-weekly"))

        // ロックだけが残るときは出さない（見直しは、依存先に答えてから始まる）
        snapshot.updateEpic("recipe-weekly") { $0.updateQuestion("Q5") { $0.state = .locked } }
        #expect(!InboxBuilder.items(from: snapshot, now: now).contains { $0.id == "recipe-weekly/questions" })
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
        // 別案は中身を名前にし、別案が 2 つあっても見分けられる
        #expect(first.choices.filter(\.isAlternative).map(\.label) == ["タイトル順にする", "著者順にする"])
        // 別案が 1 つ（3 択）と無い（2 択）カード
        #expect(cards[1].choices.map(\.id) == ["accept", "alternative-0", "fix"])
        #expect(cards[2].choices.map(\.id) == ["accept", "fix"])
    }

    /// どのカードでも、自由回答の選択肢（2 つあるときは既定の方）は推奨の対角（右手は ↙・左手は ↘）にあり、「自由回答」の札が付く
    @Test
    func freeTextChoicesSitOppositeRecommended() throws {
        let cards = DeckBuilder.cards(from: snapshot, scope: .all) + DeckBuilder.cards(from: snapshot, scope: .allVerifications)
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
            // 実機確認は、リリースが進行中なら「問題あり」が 2 つ（このリリース・次のリリース）。対角にあるのは既定の方
            let right = SwipeLayout.directions(count: card.choices.count, hand: .right)
            let index = try #require(card.choices.indices.first { card.choices[$0].asksText && right[$0] == .downLeft })
            #expect(card.choices.first?.isRecommended == true)
            #expect(SwipeLayout.directions(count: card.choices.count, hand: .right)[index] == .downLeft)
            #expect(SwipeLayout.directions(count: card.choices.count, hand: .left)[index] == .downRight)
        }
    }

    /// 読み上げでも札（推奨・自由回答・別案）と方向が分かる
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
            "タイトル順にする（別案・左上へスワイプ）",
            "直してほしい（自由回答・左下へスワイプ）",
            "著者順にする（別案・右下へスワイプ）"
        ])
    }

    /// 実機確認のカードは確認したを先頭にする（習慣ログは 1.4.0 のリリースが進行中なので、「問題あり」が 2 つになる）
    @Test
    func verificationCardPutsConfirmedFirst() {
        let cards = DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review"))
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.choices.map(\.id) == ["confirmed", "problem", "problem.release"] })
    }

    /// リポジトリにリリースが進行中なら、「問題あり」を「このリリースで直す」と「次のリリースで直す」に分ける。
    /// 既定（推奨の対角）は、epic がその release ブランチを作る前にマージされていれば「このリリース」、後なら「次のリリース」
    @Test
    func verificationProblemOffersReleaseWhileReleaseIsOpen() throws {
        var snapshot = snapshot
        let epic = try #require(snapshot.epic("habit-review"))
        guard case let .merged(mergedAt, _)? = epic.finalReview?.state else {
            Issue.record("habit-review がマージ済みでない")
            return
        }
        // 習慣ログの 1.4.0（デモ）は、振り返りの epic をマージした後に release ブランチを作った
        let index = try #require(snapshot.submissions.firstIndex { $0.repositoryID == epic.repositoryID && $0.version == "1.4.0" })
        snapshot.submissions[index].branchCreatedAt = mergedAt.addingTimeInterval(60)
        let included = try #require(DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review")).first)
        // 右手の 3 択は ↗（確認した）・↖・↙。推奨の対角（↙）に既定の「問題あり」を置く
        #expect(included.choices.map(\.id) == ["confirmed", "problem", "problem.release"])
        guard case let .askText(request) = included.choices[2].action,
              case let .verificationProblem(_, _, version) = request.purpose else {
            Issue.record("このリリースで直すが文を書く選択肢でない")
            return
        }
        #expect(version == "1.4.0")

        // release ブランチを作った後にマージした epic は、次のリリースで直すのが既定
        snapshot.submissions[index].branchCreatedAt = mergedAt.addingTimeInterval(-60)
        let later = try #require(DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review")).first)
        #expect(later.choices.map(\.id) == ["confirmed", "problem.release", "problem"])

        // リリースが終わったら、分けない
        snapshot.submissions[index].end = .distributed
        let ended = try #require(DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review")).first)
        #expect(ended.choices.map(\.id) == ["confirmed", "problem"])
    }

    /// 実機確認の一覧から開く山札は、アプリをまたいで実機確認だけを、新しくマージした epic から流す。TestFlight の版が無い項目と、
    /// 配信した版の確認（献立メモの 2.0.1 を配信して畳んだ epic）は出さない
    @Test
    func allVerificationsScopeSpansEpics() throws {
        var snapshot = snapshot
        let epicIDs = DeckBuilder.cards(from: snapshot, scope: .allVerifications).map(\.epicID)
        #expect(epicIDs == ["rain-widget", "rain-widget", "rain-widget", "habit-review", "habit-review"])
        // 畳んだ epic も、その epic だけの山札なら流せる
        #expect(DeckBuilder.cards(from: snapshot, scope: .verifications("recipe-cart")).count == 2)

        // 積読の検索の版が TestFlight に上がると、その項目も並ぶ
        let index = try #require(snapshot.epics.firstIndex { $0.id == "tsundoku-search" })
        let items = try #require(snapshot.epics[index].finalReview?.verifications)
        snapshot.epics[index].finalReview?.verifications = items.map { item in
            var item = item
            item.state = .ready(build: "2.1.0 (88)")
            return item
        }
        let cards = DeckBuilder.cards(from: snapshot, scope: .allVerifications)
        #expect(Set(cards.map(\.epicID)) == ["rain-widget", "habit-review", "tsundoku-search"])
        #expect(Set(cards.map(\.repositoryID)).count == 3)
        // リリースが進行中の習慣ログだけ、「問題あり」を「このリリースで直す」と「次のリリースで直す」に分ける
        #expect(cards.filter { $0.epicID == "tsundoku-search" }.allSatisfy { $0.choices.map(\.id) == ["confirmed", "problem"] })
        #expect(cards.filter { $0.epicID == "habit-review" }.allSatisfy { $0.choices.count == 3 })
        // 質問・最終 PR の判断のカードは混ぜない
        #expect(cards.count == 7)
    }

    /// まとめて判断するはアプリをまたいで流す。実機確認は入れない（実機確認の一覧から流す）
    @Test
    func allScopeSpansApps() {
        let cards = DeckBuilder.cards(from: snapshot, scope: .all)
        #expect(Set(cards.map(\.repositoryID)).count >= 3)
        #expect(cards.count == 7)
        #expect(!cards.contains { card in
            if case .verification = card.content { true } else { false }
        })
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
