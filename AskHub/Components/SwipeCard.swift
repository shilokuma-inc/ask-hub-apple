import SwiftUI

/// 斜めにスワイプして選ぶカード。一定の量を超えて離すと決まり、カードがその方向へ飛んでいく。
///
/// スワイプのほかに、選択肢を押す・数字キー（Mac）・VoiceOver の操作でも選べる。
/// デッキでは一番上のカードだけを `isInteractive` にし、後ろのカードは重ねて見せるだけにする
///
/// 自由回答の選択肢（`heldChoices`）は、決まっても飛ばさずにその方向で止め、`releaseToken` が変わったら飛ばす
struct SwipeCard<Content: View>: View {
    let directions: [SwipeDirection]
    let choiceLabels: [String]
    @Binding var drag: SwipeDragState
    let isInteractive: Bool
    /// 決まっても飛ばさず、その方向の決まる位置で止める選択肢（自由回答）。止めたら `onHold` を呼ぶ
    let heldChoices: Set<Int>
    /// 変わったら、止めていたカードを飛ばして `onCommit` を呼ぶ（文を書くシートで送ったとき）
    let releaseToken: Int
    /// 止めたとき（デッキが文を書くシートを出す）
    let onHold: (Int) -> Void
    /// 変わったら、飛ばしたカードを元の位置に戻す（文を書くシートを閉じたときなど）
    let resetToken: Int
    let onCommit: (Int) -> Void
    /// 決まってカードが飛び始めたとき（`onCommit` より先に呼ぶ。後ろのカードをめくり始めるため）。
    /// 自由回答で止めている間は呼ばず、シートで送って飛ばすときに呼ぶ
    let onLeave: (Int) -> Void
    @ViewBuilder let content: (_ commit: @escaping (Int) -> Void) -> Content

    @State private var offset: CGSize
    @State private var isLeaving = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 自由回答の方向で止めている選択肢。止めている間はスワイプでも選択肢でも選ばない
    @State private var held: Int?

    static var cornerRadius: CGFloat { 28 }

    init(
        directions: [SwipeDirection],
        choiceLabels: [String],
        drag: Binding<SwipeDragState>,
        isInteractive: Bool = true,
        heldChoices: Set<Int> = [],
        releaseToken: Int = 0,
        resetToken: Int = 0,
        onCommit: @escaping (Int) -> Void,
        onLeave: @escaping (Int) -> Void = { _ in },
        onHold: @escaping (Int) -> Void = { _ in },
        @ViewBuilder content: @escaping (_ commit: @escaping (Int) -> Void) -> Content
    ) {
        self.directions = directions
        self.choiceLabels = choiceLabels
        _drag = drag
        self.isInteractive = isInteractive
        self.heldChoices = heldChoices
        self.releaseToken = releaseToken
        self.onHold = onHold
        self.resetToken = resetToken
        self.onCommit = onCommit
        self.onLeave = onLeave
        self.content = content
        // 撮影のためにスワイプの途中の状態から始めるときは、その向きに少し動かしておく
        let state = drag.wrappedValue
        if isInteractive, let candidate = state.candidate, directions.indices.contains(candidate) {
            let distance = SwipeLayout.commitDistance * state.progress * 0.6
            let unit = directions[candidate].unit
            _offset = State(initialValue: CGSize(width: unit.dx * distance, height: unit.dy * distance))
        } else {
            _offset = State(initialValue: .zero)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content(commit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.background, in: shape)
            .clipShape(shape)
            // 札らしく見せるため、内側に白い縁、外側に細い線と影を付ける
            .overlay(shape.inset(by: 3).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            // 決まる量を超えたら、カードの縁もその方向の色の太い線にする
            .overlay(shape.strokeBorder(thresholdEdge, lineWidth: 3))
            .shadow(color: .black.opacity(isInteractive ? 0.16 : 0.08), radius: isInteractive ? 20 : 10, y: isInteractive ? 12 : 6)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width) / 26), anchor: .bottom)
            .gesture(dragGesture, isEnabled: isInteractive && !directions.isEmpty && !isLeaving)
            .sensoryFeedback(.selection, trigger: isInteractive ? drag.candidate : nil)
            .sensoryFeedback(.impact(weight: .medium), trigger: isInteractive && drag.isPastThreshold) { _, isPast in isPast }
            .focusable(isInteractive && !directions.isEmpty)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(characters: .decimalDigits) { press in
                // 自由記述の入力欄で打った数字もここに届く。選択肢が無いカードでは何もしない
                guard isInteractive, let index = SwipeLayout.choiceIndex(forKey: press.characters, count: directions.count) else {
                    return .ignored
                }
                commit(index)
                return .handled
            }
            .accessibilityActions {
                ForEach(Array(choiceLabels.enumerated()), id: \.offset) { index, label in
                    Button(label) { commit(index) }
                }
            }
            .accessibilityHidden(!isInteractive)
            // キー操作のためにフォーカスを当てるのは、スワイプで選べるカードだけ（自由記述のカードで勝手にキーボードを出さない）
            .onAppear { isFocused = isInteractive && !directions.isEmpty }
            .onChange(of: isInteractive) { isFocused = isInteractive && !directions.isEmpty }
            .onChange(of: releaseToken) {
                // `held` を残したまま選び直すので、`commit` は止めずに飛ばす
                if let held {
                    isLeaving = false
                    commit(held)
                }
            }
            .onChange(of: resetToken) {
                if held != nil {
                    held = nil
                    withAnimation(.easeOut(duration: 0.2)) {
                        drag = SwipeDragState()
                    }
                }
                isLeaving = false
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                    offset = .zero
                }
            }
    }

    private var thresholdEdge: Color {
        guard isInteractive, drag.isPastThreshold, let candidate = drag.candidate, directions.indices.contains(candidate) else {
            return .clear
        }
        return directions[candidate].edge
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                offset = value.translation
                let candidate = SwipeLayout.candidate(for: value.translation, directions: directions)
                drag = SwipeDragState(
                    candidate: candidate,
                    progress: candidate == nil ? 0 : SwipeLayout.progress(for: value.translation)
                )
            }
            .onEnded { value in
                let candidate = drag.candidate
                    ?? SwipeLayout.candidate(for: value.predictedEndTranslation, directions: directions)
                if let candidate, SwipeLayout.commits(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                    commit(candidate)
                } else {
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                        offset = .zero
                        drag = SwipeDragState()
                    }
                }
            }
    }

    private func commit(_ index: Int) {
        // 前に別のカードが割り込んでも、止めていたカードは飛ばして送る
        guard isInteractive || held == index, directions.indices.contains(index), !isLeaving else {
            return
        }
        if heldChoices.contains(index), held != index {
            hold(index)
            return
        }
        isLeaving = true
        let unit = directions[index].unit
        drag = SwipeDragState(candidate: index, progress: 1)
        withAnimation(.easeOut(duration: 0.26)) {
            offset = CGSize(width: unit.dx * 760, height: unit.dy * 760)
        }
        onLeave(index)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            onCommit(index)
            withAnimation(.easeOut(duration: 0.2)) {
                drag = SwipeDragState()
            }
        }
    }

    /// 自由回答: 飛ばさずに、その方向の決まる位置で止めて知らせる（デッキが文を書くシートを出す）。
    /// 決まる量を超えたときの傾き・縁の色・背景の色は、止めている間も出したままにする
    private func hold(_ index: Int) {
        held = index
        isLeaving = true
        drag = SwipeDragState(candidate: index, progress: 1)
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2)) {
            offset = SwipeHold.offset(for: directions[index])
        }
        onHold(index)
    }
}
