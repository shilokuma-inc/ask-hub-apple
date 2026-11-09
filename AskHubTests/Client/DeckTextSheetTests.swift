@testable import AskHub
import CoreGraphics
import Foundation
import Testing

/// まとめて判断するの文を書くシート: 何について書いているかの行と、シートを開いている間の札を置く領域
@MainActor
struct DeckTextSheetTests {
    private let snapshot = DemoScenario.standard.snapshot(now: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: 何について書いているか

    /// アプリの名前・札の種類・題を出す
    @Test
    func subjectShowsAppKindAndTitle() throws {
        let card = try #require(DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review")).first)
        let appName = snapshot.repository(card.repositoryID)?.appName
        let subject = TextRequestSheet.Subject(card: card, appName: appName)
        #expect(subject.context == "習慣ログ · 実機で確かめる · TestFlight 1.4.0 (52)")
        #expect(subject.title == "振り返りの画面を日曜の夜に開ける")
    }

    /// アプリの名前が分からなければ、札の種類だけを出す
    @Test
    func subjectWithoutAppNameShowsKindOnly() throws {
        let card = try #require(DeckBuilder.cards(from: snapshot, scope: .verifications("habit-review")).first)
        #expect(TextRequestSheet.Subject(card: card, appName: nil).context == card.kindLabel)
    }

    // MARK: 札を置く領域

    /// キーボードで高さだけ縮んだときは、シートを開く前の大きさのまま置く
    @Test
    func keepsAreaWhenKeyboardShrinksHeight() {
        let before = CGSize(width: 390, height: 646)
        #expect(DecisionDeckView.deckArea(CGSize(width: 390, height: 344), beforeSheet: before) == before)
    }

    /// シートを開いていないとき・幅が変わったとき（画面を回したとき）・広がったときは、今の大きさで置く
    @Test(arguments: [
        (CGSize(width: 390, height: 344), CGSize?.none),
        (CGSize(width: 844, height: 300), CGSize(width: 390, height: 646)),
        (CGSize(width: 390, height: 700), CGSize(width: 390, height: 646))
    ])
    func usesCurrentArea(available: CGSize, beforeSheet: CGSize?) {
        #expect(DecisionDeckView.deckArea(available, beforeSheet: beforeSheet) == available)
    }
}
