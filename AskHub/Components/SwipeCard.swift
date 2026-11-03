import SwiftUI

/// 斜めにスワイプして選ぶカード。一定の量を超えて離すと決まり、カードがその方向へ飛んでいく。
///
/// スワイプのほかに、選択肢を押す・数字キー（Mac）・VoiceOver の操作でも選べる。
/// デッキでは一番上のカードだけを `isInteractive` にし、後ろのカードは重ねて見せるだけにする
struct SwipeCard<Content: View>: View {
    let directions: [SwipeDirection]
    let choiceLabels: [String]
    @Binding var drag: SwipeDragState
    let isInteractive: Bool
    /// 変わったら、飛ばしたカードを元の位置に戻す（文を書くシートを閉じたときなど）
    let resetToken: Int
    let onCommit: (Int) -> Void
    @ViewBuilder let content: (_ commit: @escaping (Int) -> Void) -> Content

    @State private var offset: CGSize
    @State private var isLeaving = false
    @FocusState private var isFocused: Bool

    static var cornerRadius: CGFloat { 28 }

    init(
        directions: [SwipeDirection],
        choiceLabels: [String],
        drag: Binding<SwipeDragState>,
        isInteractive: Bool = true,
        resetToken: Int = 0,
        onCommit: @escaping (Int) -> Void,
        @ViewBuilder content: @escaping (_ commit: @escaping (Int) -> Void) -> Content
    ) {
        self.directions = directions
        self.choiceLabels = choiceLabels
        _drag = drag
        self.isInteractive = isInteractive
        self.resetToken = resetToken
        self.onCommit = onCommit
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
                guard isInteractive, let number = Int(press.characters), (1...directions.count).contains(number) else {
                    return .ignored
                }
                commit(number - 1)
                return .handled
            }
            .accessibilityActions {
                ForEach(Array(choiceLabels.enumerated()), id: \.offset) { index, label in
                    Button(label) { commit(index) }
                }
            }
            .accessibilityHidden(!isInteractive)
            .onAppear { isFocused = isInteractive }
            .onChange(of: isInteractive) { isFocused = isInteractive }
            .onChange(of: resetToken) {
                isLeaving = false
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                    offset = .zero
                }
            }
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
        guard isInteractive, directions.indices.contains(index), !isLeaving else {
            return
        }
        isLeaving = true
        let unit = directions[index].unit
        drag = SwipeDragState(candidate: index, progress: 1)
        withAnimation(.easeOut(duration: 0.26)) {
            offset = CGSize(width: unit.dx * 760, height: unit.dy * 760)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            onCommit(index)
            withAnimation(.easeOut(duration: 0.2)) {
                drag = SwipeDragState()
            }
        }
    }
}
