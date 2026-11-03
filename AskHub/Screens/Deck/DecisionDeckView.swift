import SwiftUI

/// 判断のカードを 1 枚ずつ流す画面。スワイプで選ぶと、取り消しの猶予の後に送り、次のカードを出す
struct DecisionDeckView: View {
    let scope: DeckScope

    @Environment(ClientStore.self) private var store
    @AppStorage(SwipePreferences.handKey) private var hand: Handedness = .right
    @State private var drag = Self.initialDrag
    /// 「あとで」にしたカード（このデッキの中だけで後ろに回す）
    @State private var skippedIDs: [DeckCard.ID] = []
    @State private var textRequest: TextRequest?
    @State private var detailCard: DeckCard?
    /// 文を書くシートを閉じたときに、飛んでいったカードを戻すための番号
    @State private var generation = 0

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
                let size = Self.cardSize(in: proxy.size)
                ZStack {
                    if cards.isEmpty {
                        DeckEmptyView(scope: scope)
                    }
                    // 後ろの 2 枚を少し傾けて重ね、カードのパックをめくる感じにする
                    ForEach(Array(cards.prefix(3).enumerated().reversed()), id: \.element.id) { depth, card in
                        stackedCard(card, depth: depth, size: size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(y: -10)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: cards.prefix(3).map(\.id))
            if let current {
                secondaryActions(current)
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
        .sheet(item: $textRequest) { request in
            TextRequestSheet(request: request) { text in
                textRequest = nil
                send(request.intent(text: text), card: current, label: request.title)
            } onCancel: {
                textRequest = nil
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

    /// カードの大きさ。どのカードも同じ大きさの札にする
    static func cardSize(in available: CGSize) -> CGSize {
        let width = min(available.width - 44, 440)
        let height = min(available.height - 64, width * 1.55)
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    /// 重ねたカード。後ろのカードは、前のカードを動かすほど少し持ち上がり、前のカードが飛ぶと前に出てくる
    private func stackedCard(_ card: DeckCard, depth: Int, size: CGSize) -> some View {
        let directions = SwipeLayout.directions(count: card.choices.count, hand: hand)
        let isTop = depth == 0
        let lift = isTop ? 0 : CGFloat(drag.progress) * 0.6
        let position = CGFloat(depth) - lift
        let tilt = depth.isMultiple(of: 2) ? 2.2 : -2.6
        return SwipeCard(
            directions: directions,
            choiceLabels: card.choices.map(\.label),
            drag: isTop ? $drag : .constant(SwipeDragState()),
            isInteractive: isTop,
            resetToken: generation
        ) { index in
            choose(card, index: index)
        } content: { commit in
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
        .frame(width: size.width, height: size.height)
        .scaleEffect(1 - 0.05 * position)
        .offset(y: 16 * position)
        .rotationEffect(.degrees(isTop ? 0 : tilt * Double(position)))
        .allowsHitTesting(isTop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isTop ? "deckCard.top" : "deckCard.back")
        .zIndex(Double(-depth))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.86)), removal: .identity))
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
                if !question.options.isEmpty {
                    Button("おまかせ", systemImage: "wand.and.sparkles") {
                        send(.delegate(epicID: card.epicID, questionID: question.id), card: card, label: "おまかせ")
                    }
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
        .font(.subheadline)
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
            textRequest = request
        }
    }

    private func send(_ intent: HumanIntent, card: DeckCard?, label: String) {
        let appName = card.flatMap { store.repository($0.repositoryID)?.appName } ?? ""
        let kind = card?.kindLabel ?? ""
        // 前のカードが消えると、後ろのカードがばねのように前へ出てくる
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            store.enqueue(intent, message: "\(appName) · \(kind): \(label)", itemID: card?.id)
            skippedIDs.removeAll { $0 == card?.id }
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
