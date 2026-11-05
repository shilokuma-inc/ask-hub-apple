import SwiftUI

/// 判断のカードを 1 枚ずつ流す画面。スワイプで選ぶと、取り消しの猶予の後に送り、次のカードを出す。
///
/// デッキは山札と捨て札として見せる（`DrawDeck`）。前の札を飛ばすと、山札から次の札が引かれ、中身の格（`CardGrade`）に合わせた演出で表に返る
struct DecisionDeckView: View {
    let scope: DeckScope

    @Environment(ClientStore.self) private var store
    @AppStorage(SwipePreferences.handKey) private var hand: Handedness = .right
    @State private var drag = Self.initialDrag
    /// 「あとで」にしたカード（このデッキの中だけで後ろに回す）
    @State private var skippedIDs: [DeckCard.ID] = []
    @State private var textRequest: TextRequest?
    @State private var detailCard: DeckCard?
    /// 自由回答の方向で止めたカード（シートで送ったら飛ばし、閉じたら戻す）
    @State private var hold = SwipeHold()
    /// 文を書くシートを閉じたときに、止めたカードを元の位置に戻すための番号
    @State private var generation = 0
    /// 次のカードをめくる向き。前のカードを飛ばした向きに合わせ、右へ飛ばしたら右へ返す
    @State private var flipDirection: Double = 1
    /// 飛び始めたカード。送るのを待たずに、すぐ山札から次のカードを引き始める
    @State private var leavingID: DeckCard.ID?
    /// 最後に飛ばしたカードと方向（捨て札の縁の色に使う）
    @State private var lastThrow: DeckThrow?
    /// 文を書くシートを開く前の、札を置く領域の大きさ
    @State private var deckAreaBeforeSheet: CGSize?
    /// 文を書くシートを開いてから閉じ終わるまで（閉じたあとキーボードが下がる間も含む）、札を開く前の大きさのまま置く
    @State private var keepsDeckArea = false

    private var cards: [DeckCard] {
        let all = store.deckCards(scope)
        return all.filter { !skippedIDs.contains($0.id) } + skippedIDs.compactMap { id in all.first { $0.id == id } }
    }

    var body: some View {
        let current = cards.first
        let directions = SwipeLayout.directions(count: current?.choices.count ?? 0, hand: hand)
        VStack(spacing: 12) {
            DeckProgressHeader(scope: scope)
            GeometryReader { proxy in
                let area = Self.deckArea(proxy.size, beforeSheet: keepsDeckArea ? deckAreaBeforeSheet : nil)
                let size = Self.cardSize(in: area)
                drawDeck(size: size)
                    .frame(width: area.width, height: area.height)
                .offset(y: -10)
                .onChange(of: proxy.size, initial: true) { _, newSize in
                    if !keepsDeckArea {
                        deckAreaBeforeSheet = newSize
                    }
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: cards.prefix(3).map(\.id))
            if let current {
                secondaryActions(current)
                    .keepsControlSize()
            }
        }
        .padding(.bottom, 8)
        // 方向ごとの色は、画面の四隅からにじませる（行き先を文字ではなく色で示す）
        .background {
            SwipeBackdrop(directions: directions, drag: drag)
                .animation(.easeOut(duration: 0.15), value: drag)
                .ignoresSafeArea()
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .hidesTabBar()
        .onChange(of: textRequest) { _, request in
            if request != nil {
                keepsDeckArea = true
            }
        }
        .sheet(item: $textRequest, onDismiss: textRequestDismissed) { request in
            // 何について書いているか（止めた札・説明を求める札）を、シートの上にも出す
            TextRequestSheet(
                request: request,
                subject: current.map { textSubject($0) },
                focusesOnAppear: Self.focusesTextOnAppear
            ) { text in
                textRequest = nil
                if !hold.send(text) {
                    send(request.intent(text: text), card: current, label: request.title)
                }
            } onCancel: {
                textRequest = nil
                // 飛ばしたカードが戻るので、めくりかけた次のカードも裏に戻す
                leavingID = nil
                generation += 1
            }
        }
        .sheet(item: $detailCard) { card in
            DeckCardDetailSheet(card: card)
        }
    }

    private static var initialDrag: SwipeDragState {
        #if DEBUG
        DemoLaunch.dragPreview() ?? SwipeDragState()
        #else
        SwipeDragState()
        #endif
    }

    private var title: String {
        switch scope {
        case .all: "まとめて判断する"
        case .questions: "質問に答える"
        case .decisions: "判断を確かめる"
        case .verifications: "実機で確かめる"
        }
    }

    /// 文を書くシートを開いてすぐ、入力欄にフォーカスを当てるか。
    /// iOS では当てずにキーボードを出さず、シートの上に止めた札を見せる。入力欄を押すとキーボードが出る（ユーザーの決定。2026-11-06）。
    /// Mac はソフトウェアキーボードで札が隠れないので、開いてすぐ書けるようにする
    private static var focusesTextOnAppear: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    /// カードの大きさ。どのカードも同じ大きさの札にする
    static func cardSize(in available: CGSize) -> CGSize {
        let width = min(available.width - 44, 440)
        let height = min(available.height - 64, width * 1.55)
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    /// 札を置く領域。文を書くシートでキーボードが出ると、この画面の外側の層で領域が縮み（`ignoresSafeArea(.keyboard)` では戻らない）、
    /// シートの後ろの札が縦に詰められる。幅が同じまま高さだけ縮んだときは、シートを開く前の大きさのまま置く（画面を回したときは今の大きさ）
    static func deckArea(_ available: CGSize, beforeSheet: CGSize?) -> CGSize {
        guard let beforeSheet, beforeSheet.width == available.width, beforeSheet.height > available.height else {
            return available
        }
        return beforeSheet
    }

    /// 山札と捨て札。山札の上の札は裏向きで、前を飛ばすと次の札が引かれて、格に合わせた演出で表に返る
    private func drawDeck(size: CGSize) -> some View {
        DrawDeck(
            cards: cards,
            size: size,
            leavingID: leavingID,
            lastThrow: lastThrow,
            direction: flipDirection,
            hand: hand,
            grade: grade
        ) { card in
            store.repository(card.repositoryID)
        } face: { card, depth in
            swipeCard(card, depth: depth)
        } back: { card in
            DeckCardBack(repository: store.repository(card.repositoryID))
        } empty: {
            DeckEmptyView(scope: scope)
        }
    }

    /// 札の格。飛び始めた札は、答えたものとして数える（最後の 1 枚が、前を答えた瞬間に先へ進める札に変わる）
    private func grade(_ card: DeckCard) -> CardGrade {
        CardGrade(card: card, epic: store.epic(card.epicID), remaining: cards.filter { $0.id != leavingID })
    }

    /// 表の面。前のカード（depth 0）だけをスワイプで選べるようにする
    private func swipeCard(_ card: DeckCard, depth: Int) -> some View {
        let directions = SwipeLayout.directions(count: card.choices.count, hand: hand)
        let isTop = depth == 0
        return SwipeCard(
            directions: directions,
            choiceLabels: card.choices.map(\.label),
            drag: isTop ? $drag : .constant(SwipeDragState()),
            isInteractive: isTop,
            heldChoices: SwipeHold.heldChoices(card.choices),
            releaseToken: hold.releaseToken,
            resetToken: generation
        ) { index in
            choose(card, index: index)
        } onLeave: { index in
            flipDirection = directions[index].unit.dx < 0 ? -1 : 1
            leavingID = card.id
            lastThrow = DeckThrow(id: card.id, direction: directions[index])
        } onHold: { index in
            holdForText(card, index: index)
        } content: { commit in
            VStack(spacing: 0) {
                // 慎重に決めてほしい札は、表の一番上に警告の帯を出す（札と一緒に動く）
                if let caution = card.caution {
                    CautionStrip(caution: caution)
                }
                DeckCardContent(
                    card: card,
                    repository: store.repository(card.repositoryID),
                    epic: store.epic(card.epicID),
                    directions: directions,
                    drag: isTop ? drag : SwipeDragState(),
                    remaining: isTop ? cards.count : nil,
                    commit: commit
                ) { text in
                    if case .question(let question) = card.content {
                        send(.answer(epicID: card.epicID, questionID: question.id, optionID: nil, note: text), card: card, label: "回答")
                    }
                }
            }
        }
    }

    @ViewBuilder private func secondaryActions(_ card: DeckCard) -> some View {
        HStack(spacing: 10) {
            switch card.content {
            case .question(let question):
                Button("説明を求める", systemImage: "text.bubble") {
                    textRequest = TextRequest(
                        title: "説明を求める",
                        prompt: "何が分からないか（任意）",
                        purpose: .explanation(epicID: card.epicID, questionID: question.id),
                        allowsEmpty: true
                    )
                }

            case .decision:
                if case .decisions(let epicID) = scope, cards.count > 1 {
                    Button("まとめて OK", systemImage: "checkmark.circle") {
                        send(.acceptAllDecisions(epicID: epicID), card: card, label: "残り \(cards.count) 件をまとめて OK")
                    }
                }

            case .verification:
                Button("あとで", systemImage: "clock") {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                        skippedIDs.append(card.id)
                    }
                }
            }
            Button("詳しく", systemImage: "doc.text.magnifyingglass") { detailCard = card }
        }
        .buttonStyle(.glass)
        .appFont(.subheadline)
        .padding(.horizontal)
    }

    private func choose(_ card: DeckCard, index: Int) {
        guard card.choices.indices.contains(index) else {
            return
        }
        let choice = card.choices[index]
        switch choice.action {
        case .send(let intent):
            send(intent, card: card, label: choice.label)

        case .askText(let request):
            // 止めたカードが、シートで送って飛び終わったとき
            if let text = hold.finish() {
                send(request.intent(text: text), card: card, label: request.title)
            } else {
                textRequest = request
            }
        }
    }

    /// 自由回答の方向で止めたカード。飛ばさずに、文を書くシートを出す
    private func holdForText(_ card: DeckCard, index: Int) {
        guard card.choices.indices.contains(index), case .askText(let request) = card.choices[index].action else {
            return
        }
        hold.start()
        textRequest = request
    }

    private func textSubject(_ card: DeckCard) -> TextRequestSheet.Subject {
        TextRequestSheet.Subject(card: card, appName: store.repository(card.repositoryID)?.appName)
    }

    /// 文を書くシートが閉じたとき。送ったなら止めたカードを飛ばし、送らずに閉じたなら（下へ払って閉じたときも）元の位置に戻す
    private func textRequestDismissed() {
        keepsDeckArea = false
        if hold.sheetDismissed() {
            generation += 1
        }
    }

    private func send(_ intent: HumanIntent, card: DeckCard?, label: String) {
        let appName = card.flatMap { store.repository($0.repositoryID)?.appName } ?? ""
        let kind = card?.kindLabel ?? ""
        // 前のカードが消えると、山札から引いた次のカードが前に置かれる
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            store.enqueue(intent, message: "\(appName) · \(kind): \(label)", itemID: card?.id)
            skippedIDs.removeAll { $0 == card?.id }
            leavingID = nil
        }
    }
}

/// スワイプの設定（持ち手）
enum SwipePreferences {
    static let handKey = "swipeHand"
}

/// 質問のときは、質問ごとの状態の帯を上に出す
private struct DeckProgressHeader: View {
    let scope: DeckScope
    @Environment(ClientStore.self) private var store

    var body: some View {
        if case .questions(let epicID) = scope, let epic = store.epic(epicID) {
            QuestionStatusStrip(epic: epic)
                .padding(.horizontal)
                .padding(.top, 4)
        }
    }
}

/// 答えられるカードが無いとき。説明待ち・ロックが残っていれば、その理由を出す
private struct DeckEmptyView: View {
    let scope: DeckScope
    @Environment(ClientStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("判断できるものはありません", systemImage: "checkmark.circle")
        } description: {
            Text(detail)
        }
    }

    private var detail: String {
        guard case .questions(let epicID) = scope, let epic = store.epic(epicID) else {
            return "新しい判断が来たら知らせます"
        }
        let explaining = epic.questions.filter(\.isAwaitingExplanation).count
        let locked = epic.questions.filter { $0.state == .locked || $0.state == .reviewing }.count
        if explaining + locked == 0 {
            return epic.stage == .questions ? "回答を確かめています" : "すべての質問が決まりました"
        }
        var parts: [String] = []
        if explaining > 0 {
            parts.append("説明待ち \(explaining)（Claude が書いています）")
        }
        if locked > 0 {
            parts.append("ロック \(locked)（依存先の回答の後に見直します）")
        }
        return parts.joined(separator: "\n") + "\n届いたら知らせます"
    }
}
