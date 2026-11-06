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

    /// 指で札を動かしている間（ほかの指が選択肢に触れても答えないため）
    @State private var isDragging = false
    @State private var offset: CGSize
    @State private var isLeaving = false
    /// スワイプしている間の動きの状態（持ち上げ・つかんだ所・離した後の動き・手応え）
    @State private var motion = SwipeCardMotion()
    @State private var cardSize = CGSize.zero
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
        content(choose)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.background, in: shape)
            .clipShape(shape)
            // 札らしく見せるため、内側に白い縁、外側に細い線と影を付ける
            .overlay(shape.inset(by: 3).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            // 決まる量を超えたら、カードの縁もその方向の色の太い線にする
            .overlay(shape.strokeBorder(thresholdEdge, lineWidth: 3))
            .modifier(SwipeMotionEffect(
                usesDepth: usesDepth,
                isInteractive: isInteractive,
                offset: offset,
                motion: motion,
                drag: drag,
                directions: directions
            ))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
            .swipeDragGesture(
                isEnabled: isInteractive && !directions.isEmpty && !isLeaving,
                onPress: pressed,
                onChanged: dragChanged,
                onEnded: dragEnded
            )
            .sensoryFeedback(.selection, trigger: isInteractive ? drag.candidate : nil)
            // 決まる量を超えたら 1 回鳴らし、少し戻すまで鳴らし直さない（境目で鳴り続けないため）。選択肢を押して決めたときも鳴らす
            .sensoryFeedback(SwipeFeelMotion.detentFeedback, trigger: motion.detents)
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
                motion.isHeld = false
                if usesDepth {
                    // 飛ばした・止めていた札を、いまの位置からばねで戻す
                    settle(velocity: .zero)
                } else {
                    withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                        offset = .zero
                    }
                }
            }
    }

    private var thresholdEdge: Color {
        guard isInteractive, drag.isPastThreshold, let candidate = drag.candidate, directions.indices.contains(candidate) else {
            return .clear
        }
        return directions[candidate].edge
    }

    private func dragChanged(_ value: SwipeDragValue) {
        if usesDepth, !motion.isHeld, let start = value.startLocation {
            // Mac はクリックしただけでは知らせないので、動かし始めたところでつかむ（触れた所は、動かす前の札の中の位置）
            let current = motion.offset(at: .now, resting: offset)
            grab(at: CGPoint(x: start.x - current.width, y: start.y - current.height))
        }
        isDragging = true
        let total = motion.base + value.translation
        offset = usesDepth ? SwipeFeelGeometry.rubberBand(total, directions: directions) : total
        let candidate = SwipeLayout.candidate(for: total, directions: directions)
        drag = SwipeDragState(
            candidate: candidate,
            progress: candidate == nil ? 0 : SwipeLayout.progress(for: total)
        )
        motion.velocity = value.velocity
        motion.velocityTime = .now
        updateDetent()
    }

    /// 指を離したとき（`value`）と、取り消されたとき（nil）。取り消されたら決めずに戻す。
    /// 決めた後や戻した後に重ねて呼ばれても何もしない（Mac では、離したときにも取り消しの nil が続けて届く）
    private func dragEnded(_ value: SwipeDragValue?) {
        guard value != nil || isDragging else {
            return
        }
        isDragging = false
        motion.isHeld = false
        let base = motion.base
        motion.base = .zero
        guard !isLeaving else {
            return
        }
        guard let value else {
            settle(velocity: .zero)
            return
        }
        let total = base + value.translation
        let predicted = base + value.predictedEndTranslation
        if let candidate = SwipeLayout.candidate(for: total, directions: directions)
            ?? SwipeLayout.candidate(for: predicted, directions: directions),
           SwipeLayout.commits(translation: total, predictedEnd: predicted) {
            motion.releaseVelocity = value.velocity
            commit(candidate)
        } else {
            // 選択肢の無い向きへゴムのように縮めて動かしていたら、速さも同じだけ縮める
            let scale = hypot(offset.width, offset.height) / max(hypot(total.width, total.height), 1)
            settle(velocity: CGSize(width: value.velocity.width * scale, height: value.velocity.height * scale))
        }
    }

    /// 選択肢を押して決める。札を指で動かしている間は、ほかの指が選択肢に触れても決めない
    private func choose(_ index: Int) {
        guard !isDragging else {
            return
        }
        commit(index)
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
        updateDetent()
        fly(to: CGSize(width: unit.dx * 760, height: unit.dy * 760))
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
        updateDetent()
        park(at: SwipeHold.offset(for: directions[index]))
        onHold(index)
    }
}

/// スワイプしている間の動き。持ち上げ・つかみ直し・決まる量の手応え・離した速さで戻る・飛ぶ・止める
extension SwipeCard {
    /// 奥行きのある動きにするか（一番上の札だけ。視差効果を減らすときは、これまでの平らな動き）
    private var usesDepth: Bool {
        isInteractive && !reduceMotion
    }

    /// 指が触れた・離れた（iOS だけ）。触れた所を軸にして札を持ち上げる
    private func pressed(_ press: SwipePress) {
        switch press {
        case .down(let location):
            if usesDepth, !isLeaving {
                grab(at: location)
            }

        case .up:
            // 動かしているときは、離した後の動きを始めるとき（`dragEnded`）にいっしょに下ろす（傾きが 1 コマだけ跳ねないため）
            guard !isDragging else {
                return
            }
            motion.isHeld = false
            // 戻る途中の札をつかんで、動かさずに離したときは、そこから戻す
            if usesDepth, !isLeaving, motion.offset(at: .now, resting: offset) != .zero {
                settle(velocity: .zero)
            }
        }
    }

    /// 札をつかむ。戻っている途中の札は、いまの位置で受け止める
    private func grab(at location: CGPoint) {
        if motion.thrown != nil {
            offset = motion.offset(at: .now, resting: offset)
            motion.thrown = nil
        }
        motion.base = offset
        if cardSize.width > 0, cardSize.height > 0 {
            motion.grab = UnitPoint(
                x: min(max(location.x / cardSize.width, 0), 1),
                y: min(max(location.y / cardSize.height, 0), 1)
            )
        }
        motion.isHeld = true
    }

    /// 決まる量を超えたら 1 回だけ手応えを鳴らす。少し戻すまで鳴らし直さない
    private func updateDetent() {
        if drag.isPastThreshold {
            if motion.isDetentArmed {
                motion.isDetentArmed = false
                motion.detents += 1
            }
        } else if drag.candidate == nil || drag.progress < SwipeFeelMotion.rearmProgress {
            motion.isDetentArmed = true
        }
    }

    /// 決めずに戻す。離した速さのままばねで戻る
    private func settle(velocity: CGSize) {
        guard usesDepth else {
            withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                offset = .zero
                drag = SwipeDragState()
            }
            return
        }
        let from = motion.offset(at: .now, resting: offset)
        let speed = hypot(velocity.width, velocity.height)
        launch(SwipeThrow(from: from, to: .zero, velocity: velocity, spring: SwipeFeelMotion.returnSpring(speed: speed)))
        withAnimation(SwipeFeelMotion.returnFade) {
            offset = .zero
            drag = SwipeDragState()
        }
    }

    /// 決めた札を飛ばす。離した速さのまま飛び始める（選択肢を押したときも、弾いたように飛ぶ）
    private func fly(to target: CGSize) {
        let velocity = motion.releaseVelocity
        motion.releaseVelocity = .zero
        guard usesDepth else {
            withAnimation(.easeOut(duration: 0.26)) {
                offset = target
            }
            return
        }
        let from = motion.offset(at: .now, resting: offset)
        let delta = CGSize(width: target.width - from.width, height: target.height - from.height)
        let launch = SwipeFeelGeometry.launchVelocity(release: velocity, toward: delta)
        self.launch(SwipeThrow(from: from, to: target, velocity: launch, kind: .fling(duration: SwipeFeelMotion.flyDuration)))
        offset = target
    }

    /// 自由回答の選択肢: 止める位置へ寄せる。離した速さのまま寄って止まる
    private func park(at spot: CGSize) {
        let velocity = motion.releaseVelocity
        motion.releaseVelocity = .zero
        guard usesDepth else {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2)) {
                offset = spot
            }
            return
        }
        let from = motion.offset(at: .now, resting: offset)
        launch(SwipeThrow(from: from, to: spot, velocity: velocity, spring: SwipeFeelMotion.hold))
        offset = spot
    }

    /// 離した後の動きを始める。止まったら、時刻ごとに描くのをやめる
    private func launch(_ thrown: SwipeThrow) {
        motion.thrown = thrown
        Task {
            try? await Task.sleep(for: .seconds(thrown.duration))
            if motion.thrown == thrown {
                motion.thrown = nil
            }
        }
    }
}

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
