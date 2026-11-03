import SwiftUI

/// 札を動かすドラッグの値（iOS のパンと Mac の `DragGesture` で共通）
struct SwipeDragValue {
    var translation: CGSize
    /// 直近の速さ（pt/秒）
    var velocity: CGSize
    /// 離した勢いのまま進んだときの移動量。`DragGesture.Value.predictedEndTranslation` と同じく、速さの 0.25 秒分を足す
    var predictedEndTranslation: CGSize
    /// 触れた所（札の中の位置。動かす前の札の左上が原点）。Mac だけ。iOS は `SwipePress.down` で先に知らせる
    var startLocation: CGPoint?

    static let projection: CGFloat = 0.25

    init(translation: CGSize, velocity: CGSize) {
        self.translation = translation
        self.velocity = velocity
        startLocation = nil
        predictedEndTranslation = CGSize(
            width: translation.width + velocity.width * Self.projection,
            height: translation.height + velocity.height * Self.projection
        )
    }

    init(_ value: DragGesture.Value) {
        translation = value.translation
        velocity = value.velocity
        predictedEndTranslation = value.predictedEndTranslation
        startLocation = value.startLocation
    }
}

/// 札に指が触れた・離れた（動かし始める前から知らせる。札を持ち上げるため）。
/// `location` は札の中の位置（札の左上が原点）。iOS だけで届く（Mac はクリックしただけでは知らせない）
enum SwipePress {
    case down(location: CGPoint)
    case up
}

extension View {
    /// 札を動かすジェスチャー。指を離したときは `onEnded` に値を、取り消されたとき（2 本目の指・システムの割り込みなど）は nil を渡す。
    ///
    /// SwiftUI の `DragGesture` は、引いている途中に 2 本目の指が札に触れると値が止まり、2 本目を先に離すと `onEnded` が来ない
    /// （札が途中で止まったまま戻らない）。2 本目を置いたまま 1 本目を離すと、2 本目の位置を起点にした移動量で `onEnded` が来て、
    /// 引いていない向きに決まることもある。そのため iOS では UIKit のパンで 1 本目の指だけを追い、増えた指は無視する。
    /// Mac（マウスとトラックパッド）は `DragGesture` のまま、トラックパッドのピンチなどで取り消されたときに備えて `@GestureState` で終わりに気づく
    func swipeDragGesture(
        isEnabled: Bool,
        onPress: @escaping (SwipePress) -> Void = { _ in },
        onChanged: @escaping (SwipeDragValue) -> Void,
        onEnded: @escaping (SwipeDragValue?) -> Void
    ) -> some View {
        modifier(SwipeDragGestureModifier(isEnabled: isEnabled, onPress: onPress, onChanged: onChanged, onEnded: onEnded))
    }
}

private struct SwipeDragGestureModifier: ViewModifier {
    let isEnabled: Bool
    let onPress: (SwipePress) -> Void
    let onChanged: (SwipeDragValue) -> Void
    let onEnded: (SwipeDragValue?) -> Void

    #if os(macOS)
    /// 取り消されたとき（`onEnded` が来ないとき）も、ドラッグが終わったことに気づくため
    @GestureState private var isDragging = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .gesture(SwipePanGesture(isEnabled: isEnabled, onPress: onPress, onChanged: onChanged, onEnded: onEnded))
        #else
        content
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($isDragging) { _, isDragging, _ in isDragging = true }
                    .onChanged { onChanged(SwipeDragValue($0)) }
                    .onEnded { onEnded(SwipeDragValue($0)) },
                isEnabled: isEnabled
            )
            .onChange(of: isDragging) { _, isDragging in
                // 離したときは `onEnded` の前か後に来る。受け手は、離した後・決めた後に nil が来ても何もしない
                if !isDragging {
                    onEnded(nil)
                }
            }
        #endif
    }
}

#if os(iOS)
/// UIKit の認識器を SwiftUI のジェスチャーとして付ける
private struct SwipePanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onPress: (SwipePress) -> Void
    let onChanged: (SwipeDragValue) -> Void
    let onEnded: (SwipeDragValue?) -> Void

    /// 触れた所を札の中の位置に直すため、SwiftUI の座標の変換を持っておく
    final class Coordinator {
        let converter: CoordinateSpaceConverter

        init(converter: CoordinateSpaceConverter) {
            self.converter = converter
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> SingleTouchPanRecognizer {
        SingleTouchPanRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: SingleTouchPanRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        let converter = context.coordinator.converter
        // 札の中の位置（.local）は、動かしている札の傾きと移動を含む。触れた瞬間に測るので、戻る途中の札もつかんだ所が分かる
        recognizer.onPress = { [onPress] press in
            switch press {
            case .down(let location):
                onPress(.down(location: converter.convert(globalPoint: location, to: .local)))

            case .up:
                onPress(.up)
            }
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: SingleTouchPanRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.value)

        case .ended:
            onEnded(recognizer.value)

        case .cancelled, .failed:
            onEnded(nil)

        default:
            break
        }
    }
}

/// 最初に触れた指だけを追うパン。ほかの指は `ignore(_:for:)` で受け取らず、最初の指を離したら終わる。
///
/// `UIPanGestureRecognizer` の派生にするのは、札の中の選択肢（SwiftUI の Button）に触れたところから引き始めても止められないため
/// （`UIGestureRecognizer` を直に派生すると、Button の認識器に止められて動かない）。
/// 移動量は、パンが始まった所からではなく指が触れた所から測る（札が指の下から遅れないため）。
/// 速さも自分で求める（`velocity(in:)` は、指を止めてから離しても止める前の速さのまま残り、迷ってから離した札が飛んでしまうため）
final class SingleTouchPanRecognizer: UIPanGestureRecognizer {
    /// 速さを求める直近の時間。離す前にこれより長く指を止めていたら、速さは 0 になる
    static let velocityWindow: TimeInterval = 0.1

    /// 最初の指が触れた・離れたとき（`down` の位置は画面の座標）
    var onPress: (SwipePress) -> Void = { _ in }

    private var touch: UITouch?
    /// 最初の指が触れていて、まだ離したことを知らせていない
    private var isPressed = false
    private var start = CGPoint.zero
    private var samples: [(time: TimeInterval, location: CGPoint)] = []

    init() {
        super.init(target: nil, action: nil)
        maximumNumberOfTouches = 1
    }

    var value: SwipeDragValue {
        guard let last = samples.last else {
            return SwipeDragValue(translation: .zero, velocity: .zero)
        }
        return SwipeDragValue(
            translation: CGSize(width: last.location.x - start.x, height: last.location.y - start.y),
            velocity: velocity
        )
    }

    /// 直近の速さ（pt/秒、画面の座標）
    private var velocity: CGSize {
        guard let last = samples.last,
              let first = samples.first(where: { last.time - $0.time <= Self.velocityWindow }),
              last.time - first.time > 0.001 else {
            return .zero
        }
        let duration = last.time - first.time
        return CGSize(width: (last.location.x - first.location.x) / duration, height: (last.location.y - first.location.y) / duration)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        var accepted = Set<UITouch>()
        for touch in touches {
            if self.touch == nil {
                self.touch = touch
                start = touch.location(in: nil)
                record(touch)
                accepted.insert(touch)
                isPressed = true
                onPress(.down(location: start))
            } else {
                ignore(touch, for: event)
            }
        }
        super.touchesBegan(accepted, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) {
            record(touch)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) {
            record(touch)
            release()
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) {
            release()
        }
        super.touchesCancelled(touches, with: event)
    }

    override func reset() {
        super.reset()
        // 途中で止められたとき（`isEnabled` を切ったときなど）も、離したことを知らせる
        release()
        touch = nil
        samples = []
    }

    private func release() {
        if isPressed {
            isPressed = false
            onPress(.up)
        }
    }

    private func record(_ touch: UITouch) {
        samples.append((touch.timestamp, touch.location(in: nil)))
        samples.removeAll { touch.timestamp - $0.time > Self.velocityWindow * 2 }
    }
}
#endif
