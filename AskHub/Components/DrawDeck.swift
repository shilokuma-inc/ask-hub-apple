import SwiftUI

/// 前の札を飛ばした札と、その方向（捨て札の縁の色に使う）
struct DeckThrow: Equatable {
    let id: DeckCard.ID
    let direction: SwipeDirection
}

/// デッキを山札と捨て札として見せる。
///
/// - 山札: 前の札の下に、残りの札が裏向きの束として重なる（縁はその札のアプリの色）。答えるほど薄くなる。
///   この先に慎重に決めてほしい札・先へ進める札・実機の確認があれば、その縁に格の色の線が出る
/// - 引く: 前の札を飛ばすと、山札の一番上の札が飛ばした向きへ引き出されながら、格（`CardGrade`）に合わせた演出で表に返り、前に置かれる。
///   開いたときの最初の札も、山札の上に裏で置いてから引いて返す
/// - 捨て札: 答えた札は、選んだ方向の色の縁の小さな札になって「済み」の束に積み上がる。取り消すと、束から戻る
/// - 終わり: 最後の 1 枚を知らせ、全部答えたら捨て札を真ん中に集めてそろえる
///
/// 視差効果を減らすときは、引く・積む・集める動きをやめてフェードで替える（束の厚みと枚数は残す）
struct DrawDeck<Face: View, Back: View, Empty: View>: View {
    let cards: [DeckCard]
    let size: CGSize
    /// 飛び始めた札（前の札）。送るのを待たずに、次の札を引き始める
    let leavingID: DeckCard.ID?
    /// 最後に飛ばした札と方向
    let lastThrow: DeckThrow?
    /// 引く向き。1 で右へ引き出して右へ返し、-1 で左
    let direction: Double
    let hand: Handedness
    /// 札の格。表に返すときの演出と、山札の縁の線の色を決める
    let grade: (DeckCard) -> CardGrade
    let repository: (DeckCard) -> TargetRepository?
    @ViewBuilder let face: (DeckCard, Int) -> Face
    @ViewBuilder let back: (DeckCard) -> Back
    @ViewBuilder let empty: () -> Empty

    /// 捨て札（このデッキを開いている間に答えた札）
    @State private var discards: [DiscardEntry] = []
    /// 捨て札に置いた回数（札の傾きを決める）
    @State private var placed = 0
    /// 全部答え終えて、捨て札を真ん中に集めたか
    @State private var isGathered = false
    /// 集めた束をそろえる（トントンと打つ）回数
    @State private var squaring = 0
    /// 束が机に当たった回数（触覚の合図）
    @State private var taps = 0
    /// 開いた直後に、前の札も山札から引いて表に返したか（それまでは裏のまま山札の上にある）
    @State private var hasDealt = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 答えた札があるときは、束を真ん中に集めてから空の画面の文言を出す
            if cards.isEmpty, discards.isEmpty || isGathered {
                empty()
                    .padding(.top, discards.isEmpty ? 0 : DrawMotion.finishSpace)
                    .transition(reveal(after: DrawMotion.emptyReveal))
            }
            discardPile
                .zIndex(-20)
            if !discards.isEmpty, !isGathered {
                DiscardCount(count: discards.count)
                    // 束の内側（右手なら左）に、束と間をあけて端をそろえる
                    .frame(width: 1, alignment: side > 0 ? .trailing : .leading)
                    .offset(
                        x: cornerOffset.width - side * (DrawMotion.miniSize.width / 2 + DrawMotion.countGap),
                        y: cornerOffset.height + DrawMotion.countLift
                    )
                    .transition(reveal(after: DrawMotion.countReveal))
                    .zIndex(-20)
            }
            if isGathered {
                DrawFinishLabel(count: discards.count)
                    .fixedSize()
                    // 集めた束のすぐ下に、上をそろえて置く
                    .frame(height: 1, alignment: .top)
                    .offset(y: DrawMotion.finishLabelTop)
                    .transition(reveal(after: DrawMotion.labelReveal))
            }
            DrawPileEdges(layers: cards.dropFirst(3).prefix(DrawMotion.maxEdges).map(edgeLayer), size: size)
                .zIndex(-10)
            ForEach(Array(cards.prefix(3).enumerated().reversed()), id: \.element.id) { depth, card in
                drawnCard(card, depth: depth)
            }
            if cards.count == 1 {
                LastCardNote()
                    .offset(y: size.height / 2 + DrawMotion.lastNoteGap)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
            }
        }
        .onChange(of: cards.map(\.id)) { old, new in
            track(old: old, new: new)
        }
        .task(id: cards.isEmpty) {
            await gatherIfFinished()
        }
        .task(id: squaring) {
            await tapTwice()
        }
        .task {
            await dealFirstCard()
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: taps)
    }

    // MARK: 山札と前の札

    /// 前の札（depth 0）と、山札の上の 2 枚。後ろの札は裏向きで、引かれると表に返る
    private func drawnCard(_ card: DeckCard, depth: Int) -> some View {
        let isTop = depth == 0
        let isNext = depth == 1 && leavingID != nil && leavingID == cards.first?.id
        // 開いた直後の前の札も裏のまま置き、少し待ってから引いて表に返す
        let isDrawn = (isTop && hasDealt) || isNext
        return RevealCard(isFaceUp: isDrawn, direction: direction, grade: grade(card)) {
            face(card, depth)
        } back: {
            back(card)
        }
        .frame(width: size.width, height: size.height)
        .modifier(DrawPull(progress: isDrawn ? 1 : 0, rest: Self.rest(depth: depth), direction: direction, isFlat: reduceMotion))
        .animation(DrawMotion.pull(drawn: isDrawn, reduceMotion: reduceMotion), value: isDrawn)
        .allowsHitTesting(isTop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isTop ? "deckCard.top" : "deckCard.back")
        // 裏向きの札は読ませない（操作の対象は前の札だけ）
        .accessibilityHidden(!isTop)
        .zIndex(Double(-depth))
        .transition(transition(for: card, depth: depth))
    }

    /// 開いたら、山札の上に裏で置いた前の札を、少し待ってから引いて表に返す（配る手応え）
    private func dealFirstCard() async {
        guard !hasDealt else {
            return
        }
        try? await Task.sleep(for: reduceMotion ? .zero : DrawMotion.dealDelay)
        hasDealt = true
    }

    /// 山札の縁の 1 枚。慎重に決めてほしい札・先へ進める札・実機の確認の縁には、格の色の線を出す（この先に来ることが分かる）
    private func edgeLayer(_ card: DeckCard) -> DrawPileEdges.Layer {
        let grade = grade(card)
        return DrawPileEdges.Layer(id: card.id, tint: tint(of: card), accent: grade == .common ? nil : grade.tone)
    }

    /// 山札の中の位置。前の札の真下に重ね、1 枚ごとに少し下へずらして厚みを見せる
    private static func rest(depth: Int) -> CGFloat {
        depth == 0 ? 0 : DrawMotion.pileBase + DrawMotion.pileStep * CGFloat(depth - 1)
    }

    private func transition(for card: DeckCard, depth: Int) -> AnyTransition {
        if let entry = discards.first(where: { $0.id == card.id }) {
            // 取り消し: 札が捨て札から戻る（全部答えた後なら、真ん中に集めた束から）
            if reduceMotion {
                return .opacity.animation(DrawMotion.fade)
            }
            let pileScale = isGathered ? DrawMotion.gatherScale : 1
            return .asymmetric(
                insertion: .modifier(
                    active: DiscardFlight(
                        offset: isGathered ? CGSize(width: 0, height: DrawMotion.gatherCenter) : cornerOffset,
                        scale: DrawMotion.miniSize.width * pileScale / max(size.width, 1),
                        rotation: isGathered ? 0 : entry.tilt
                    ),
                    identity: DiscardFlight(offset: .zero, scale: 1, rotation: 0)
                )
                .animation(DrawMotion.returnFromDiscard),
                removal: .identity
            )
        }
        // 山札の中で繰り上がる札は、同じ位置の縁と入れ替わるだけなので動かさない
        return depth == 0 ? .opacity.combined(with: .scale(scale: 0.94)) : .identity
    }

    /// 少し待ってからフェードで出し、消すときはすぐ消す（視差効果を減らすときは待たない）
    private func reveal(after delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(DrawMotion.fade.delay(reduceMotion ? 0 : delay)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    private func tint(of card: DeckCard) -> Color {
        if case let .symbol(_, tint) = repository(card)?.icon {
            return tint.color
        }
        return Theme.Tone.lavender
    }

    // MARK: 捨て札

    /// 捨て札の束。右手は右上（左手は左上）に、前の札の後ろから少しのぞかせる。全部答えたら真ん中に集める
    private var discardPile: some View {
        DiscardPile(entries: discards, isGathered: isGathered, reduceMotion: reduceMotion)
            .scaleEffect(isGathered ? DrawMotion.gatherScale : 1)
            .offset(isGathered ? CGSize(width: 0, height: DrawMotion.gatherCenter) : cornerOffset)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: squaring) { pile, bounce in
                pile.offset(y: bounce)
            } keyframes: { _ in
                DrawMotion.squareKeyframes
            }
            .id(reduceMotion ? isGathered : false)
            .transition(.opacity.animation(DrawMotion.fade))
            .allowsHitTesting(false)
    }

    /// 捨て札の束の位置（前の札の真ん中から）
    private var cornerOffset: CGSize {
        CGSize(
            width: side * (size.width / 2 - DrawMotion.cornerInset),
            height: -size.height / 2 - DrawMotion.cornerLift
        )
    }

    /// 捨て札を置く側。右手は右（推奨の ↗ の側）、左手は左
    private var side: CGFloat {
        hand == .right ? 1 : -1
    }

    /// 札が無くなったら捨て札に、戻ってきたら（取り消し）捨て札から外す
    private func track(old: [DeckCard.ID], new: [DeckCard.ID]) {
        let returned = Set(discards.map(\.id)).intersection(new)
        if !returned.isEmpty {
            withAnimation(DrawMotion.fade) {
                discards.removeAll { returned.contains($0.id) }
            }
        }
        let gone = old.filter { !new.contains($0) }
        guard !gone.isEmpty else {
            return
        }
        withAnimation(DrawMotion.drop(reduceMotion: reduceMotion)) {
            for id in gone where !discards.contains(where: { $0.id == id }) {
                let direction = lastThrow?.id == id ? lastThrow?.direction : nil
                discards.append(DiscardEntry(id: id, direction: direction, order: placed))
                placed += 1
            }
        }
    }

    /// 最後の札を置いて捨て札が落ち着いたら、束を真ん中に集めてそろえる。札が戻ったら（取り消し）元の場所に戻す
    private func gatherIfFinished() async {
        guard cards.isEmpty, !discards.isEmpty else {
            if isGathered {
                withAnimation(DrawMotion.gather(reduceMotion: reduceMotion)) {
                    isGathered = false
                }
            }
            return
        }
        try? await Task.sleep(for: DrawMotion.gatherDelay)
        guard !Task.isCancelled else {
            return
        }
        withAnimation(DrawMotion.gather(reduceMotion: reduceMotion)) {
            isGathered = true
        } completion: {
            guard isGathered, !reduceMotion else {
                return
            }
            squaring += 1
        }
    }

    /// そろえる動きの、束が机に当たるところで軽く鳴らす
    private func tapTwice() async {
        guard squaring > 0 else {
            return
        }
        for delay in DrawMotion.tapDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            taps += 1
        }
    }
}

/// 山札から引き出す動き。`progress` が 0 で山札の中、1 で前。途中で飛ばした向きへ横にずれて少し傾く
private struct DrawPull: ViewModifier, Animatable {
    var progress: Double
    /// 山札の中の位置（前からの下へのずれ）
    let rest: CGFloat
    let direction: Double
    /// 視差効果を減らすときは、横へずらさない
    let isFlat: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // 引き出している途中ほど大きく（0 と 1 で 0、真ん中で 1。ばねの行き過ぎでは戻さない）
        let arc = isFlat ? 0 : sin(min(max(progress, 0), 1) * .pi)
        content
            .rotationEffect(.degrees(DrawMotion.pullTilt * direction * arc))
            .offset(
                x: DrawMotion.pullWidth * CGFloat(direction * arc),
                y: rest * CGFloat(1 - progress) - DrawMotion.pullRise * CGFloat(arc)
            )
    }
}

/// 捨て札と前の間を行き来する札の見た目（取り消して戻るとき）
private struct DiscardFlight: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let rotation: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
    }
}

/// 山札の厚み。前の札と山札の上の 2 枚は札そのものを描き、それより下の札は縁だけを描く（その札のアプリの色）
private struct DrawPileEdges: View {
    struct Layer: Identifiable {
        let id: DeckCard.ID
        let tint: Color
        /// 縁に引く格の色の線（nil なら引かない）
        var accent: Color?
    }

    let layers: [Layer]
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwipeCard<EmptyView>.cornerRadius, style: .continuous)
        ZStack {
            ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                shape
                    .fill(fill(layer.tint))
                    .overlay(shape.inset(by: 1).strokeBorder(.white.opacity(0.75), lineWidth: 1))
                    .overlay {
                        // 見えているのは下の縁の数 pt だけなので、下の縁に沿って格の色の線を引く
                        if let accent = layer.accent {
                            shape.inset(by: 0.75).strokeBorder(accent, lineWidth: 1.5)
                        }
                    }
                    .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                    .frame(width: size.width, height: size.height)
                    .offset(y: DrawMotion.pileBase + DrawMotion.pileStep * CGFloat(index + 2))
                    .zIndex(Double(-index))
                    .transition(.identity)
            }
        }
        .shadow(color: .black.opacity(layers.isEmpty ? 0 : 0.08), radius: 8, y: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fill(_ tint: Color) -> Color {
        if colorScheme == .dark {
            return tint.mix(with: .black, by: 0.5)
        }
        // アプリの色をパステルに寄せる
        return tint.mix(with: .white, by: 0.45)
    }
}
