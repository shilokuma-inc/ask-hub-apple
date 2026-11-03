import SwiftUI

/// 斜めにスワイプして選ぶカード。一定の量を超えて離すと決まり、カードがその方向へ飛んでいく。
///
/// スワイプのほかに、選択肢を押す・数字キー（Mac）・VoiceOver の操作でも選べる
struct SwipeCard<Content: View>: View {
    let directions: [SwipeDirection]
    let choiceLabels: [String]
    @Binding var drag: SwipeDragState
    let onCommit: (Int) -> Void
    @ViewBuilder let content: (_ commit: @escaping (Int) -> Void) -> Content

    @State private var offset: CGSize
    @State private var isLeaving = false
    @FocusState private var isFocused: Bool

    init(
        directions: [SwipeDirection],
        choiceLabels: [String],
        drag: Binding<SwipeDragState>,
        onCommit: @escaping (Int) -> Void,
        @ViewBuilder content: @escaping (_ commit: @escaping (Int) -> Void) -> Content
    ) {
        self.directions = directions
        self.choiceLabels = choiceLabels
        _drag = drag
        self.onCommit = onCommit
        self.content = content
        // 撮影のためにスワイプの途中の状態から始めるときは、その向きに少し動かしておく
        let state = drag.wrappedValue
        if let candidate = state.candidate, directions.indices.contains(candidate) {
            let distance = SwipeLayout.commitDistance * state.progress * 0.6
            let unit = directions[candidate].unit
            _offset = State(initialValue: CGSize(width: unit.dx * distance, height: unit.dy * distance))
        } else {
            _offset = State(initialValue: .zero)
        }
    }

    var body: some View {
        content(commit)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(.background, in: .rect(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width) / 28), anchor: .bottom)
            .gesture(dragGesture, isEnabled: !directions.isEmpty && !isLeaving)
            .sensoryFeedback(.selection, trigger: drag.candidate)
            .sensoryFeedback(.impact(weight: .medium), trigger: drag.isPastThreshold) { _, isPast in isPast }
            .focusable(!directions.isEmpty)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(characters: .decimalDigits) { press in
                guard let number = Int(press.characters), (1...directions.count).contains(number) else {
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
            .onAppear { isFocused = true }
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
        guard directions.indices.contains(index), !isLeaving else {
            return
        }
        isLeaving = true
        let unit = directions[index].unit
        drag = SwipeDragState(candidate: index, progress: 1)
        withAnimation(.easeOut(duration: 0.24)) {
            offset = CGSize(width: unit.dx * 700, height: unit.dy * 700)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            onCommit(index)
            drag = SwipeDragState()
        }
    }
}
