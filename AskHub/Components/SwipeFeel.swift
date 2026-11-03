import SwiftUI

/// スワイプしている間の札の動きの時間・ばね・大きさ。触れると持ち上がり、つかんだ所を軸に回って奥行きのある傾きと光が付き、
/// 決まる量で手応えがあり、離した速さのまま戻る・飛ぶ。値は Simulator の録画で見比べて、触った手応えを優先して決めた
enum SwipeFeelMotion {
    /// 触れたときに持ち上げる大きさ（大きい札なので控えめにする）と、そのばね（置くときも同じばねで戻す）
    static let liftScale: CGFloat = 1.03
    static let lift = Animation.spring(duration: 0.24, bounce: 0.3)

    /// 影。置いているときはこれまでと同じで、持ち上げると深く広くする
    static let restingShadow = SwipeShadow(opacity: 0.16, radius: 20, y: 12)
    static let liftedShadow = SwipeShadow(opacity: 0.24, radius: 34, y: 26)

    /// つかんだ所を軸にした回転。札の端をつかんで 100pt 動かすと 5° 回る
    static let rotationPerPoint = 0.05
    static let maxRotation = 16.0

    /// 奥行きの傾き。決まる量まで動かすと 7°、速く動かすとさらに 6° まで傾き、合わせて 12° まで
    static let restingTilt = 7.0
    static let swayTilt = 6.0
    /// これより速く動かすと、速さの傾きが一番大きくなる（pt/秒）
    static let swaySpeed: CGFloat = 1_500
    static let maxTilt = 12.0
    static let perspective: CGFloat = 0.5
    /// 指を止めたとき、速さの傾きが消えるまでの時定数
    static let swayDecay: TimeInterval = 0.09

    /// 決まる量を超えたとき、札が向かう先へ吸い付く量と速さ
    static let detentPull: CGFloat = 8
    static let detent = Animation.snappy(duration: 0.2, extraBounce: 0.12)
    /// 決まる量を超えて鳴らした後、ここまで戻したらもう一度鳴らせるようにする（境目で鳴り続けないため）
    static let rearmProgress = 0.85

    /// 選択肢の無い向きへ引いたときのゴムの抵抗（UIScrollView と同じ係数）
    static let rubberBand: CGFloat = 0.55

    /// 決めずに離したとき、離した速さのまま戻るばね。速く離したほど少し弾む
    static func returnSpring(speed: CGFloat) -> Spring {
        Spring(duration: 0.42, bounce: 0.06 + 0.14 * min(1, speed / 1_200))
    }

    /// 戻るときの背景の色・選択肢の行の戻り方
    static let returnFade = Animation.spring(duration: 0.42, bounce: 0)
    /// 決めた札が行き先（画面の外）に着くまでの時間。離した速さで飛び出し、足りない分だけ加速する
    /// （強く弾くと加速せずにその速さのまま、もっと早く出ていく）。0.2 秒ほどで画面の外に出る（これまでと同じころ）
    static let flyDuration: TimeInterval = 0.24
    /// 選択肢を押したとき・ゆっくり離したときも、これより遅くは飛び出さない（pt/秒）
    static let launchSpeed: CGFloat = 500
    /// 自由回答の選択肢で止めるとき、離した速さのまま止める位置へ寄せる（これまでの止め方と同じばね）
    static let hold = Spring(duration: 0.3, bounce: 0.2)

    /// 決まる量を超えたときの手応え（Mac はトラックパッドで鳴らす）
    static var detentFeedback: SensoryFeedback {
        #if os(macOS)
        .alignment
        #else
        .impact(weight: .medium)
        #endif
    }
}

/// 札の影
struct SwipeShadow: Equatable {
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat

    /// 後ろの札の影（これまでと同じ）
    static let behind = Self(opacity: 0.08, radius: 10, y: 6)

    /// `other` へ `amount`（0〜1）だけ近づける
    func mixed(with other: Self, by amount: CGFloat) -> Self {
        Self(
            opacity: opacity + (other.opacity - opacity) * Double(amount),
            radius: radius + (other.radius - radius) * amount,
            y: y + (other.y - y) * amount
        )
    }
}

/// スワイプしている間の動きの計算。指の位置と速さから札の姿勢を決める（画面に依存しないので、テストで確かめる）
enum SwipeFeelGeometry {
    /// 選択肢の無い向きへは、ゴムのように抵抗して少ししか動かない。選択肢のある向きへは指に 1:1 で付いてくる
    static func rubberBand(_ translation: CGSize, directions: [SwipeDirection]) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > 0.5, !directions.isEmpty else {
            return translation
        }
        let threshold = SwipeLayout.cosineThreshold(directionCount: directions.count)
        var cosine: CGFloat = -1
        for direction in directions {
            let along = translation.width * direction.unit.dx + translation.height * direction.unit.dy
            cosine = max(cosine, along / distance)
        }
        // 選べる向きの境目で 1:1 になり、そこから 0.3 だけ外れると抵抗がいちばん強くなる
        let freedom = smoothstep(cosine, from: threshold - 0.3, to: threshold)
        let reach = SwipeLayout.commitDistance
        let banded = (1 - 1 / (distance * SwipeFeelMotion.rubberBand / reach + 1)) * reach
        let scale = (freedom * distance + (1 - freedom) * banded) / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }

    /// つかんだ所を軸にした回転。指から札の真ん中までの向きと動かした量から決める（重心が遅れてついてくる向きに回る）。
    /// 上をつかんで右へ動かすと時計回り、下をつかむと反時計回り。真ん中をつかむとほとんど回らない
    static func rotation(offset: CGSize, grab: UnitPoint) -> Angle {
        let leverX = soften((0.5 - grab.x) * 2)
        let leverY = soften((0.5 - grab.y) * 2)
        let torque = Double(leverY * offset.width - leverX * offset.height)
        let degrees = torque * SwipeFeelMotion.rotationPerPoint
        return .degrees(min(max(degrees, -SwipeFeelMotion.maxRotation), SwipeFeelMotion.maxRotation))
    }

    /// 奥行きの傾き（度のベクトル）。向かう先の縁が奥へ下がる向きで、動かした量（決まる量で `restingTilt`）と速さを足す
    static func lean(offset: CGSize, velocity: CGSize) -> CGVector {
        let reach = clamped(CGVector(dx: offset.width, dy: offset.height) / SwipeLayout.commitDistance, length: 1.3)
        let sway = clamped(CGVector(dx: velocity.width, dy: velocity.height) / SwipeFeelMotion.swaySpeed, length: 1)
        let lean = reach * SwipeFeelMotion.restingTilt + sway * SwipeFeelMotion.swayTilt
        return clamped(lean, length: SwipeFeelMotion.maxTilt)
    }

    /// 決めた札が飛び始める速さ。向かう先への成分は `launchSpeed` より遅くせず、横への成分は少しだけ残す（投げた向きに少し流れる）
    static func launchVelocity(release velocity: CGSize, toward delta: CGSize) -> CGSize {
        let distance = hypot(delta.width, delta.height)
        guard distance > 1 else {
            return velocity
        }
        let direction = CGVector(dx: delta.width / distance, dy: delta.height / distance)
        let along = velocity.width * direction.dx + velocity.height * direction.dy
        let speed = max(along, SwipeFeelMotion.launchSpeed)
        let side = clamped(
            CGVector(dx: velocity.width - direction.dx * along, dy: velocity.height - direction.dy * along),
            length: speed * 0.5
        )
        return CGSize(width: direction.dx * speed + side.dx, height: direction.dy * speed + side.dy)
    }

    /// 0〜1 になめらかにつなぐ
    private static func smoothstep(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
        let fraction = min(max((value - lower) / (upper - lower), 0), 1)
        return fraction * fraction * (3 - 2 * fraction)
    }

    /// 真ん中の近くでも少し効くように、てこの長さをやわらげる
    private static func soften(_ value: CGFloat) -> CGFloat {
        let magnitude = pow(min(abs(value), 1), 0.6)
        return value < 0 ? -magnitude : magnitude
    }

    private static func clamped(_ vector: CGVector, length: CGFloat) -> CGVector {
        let current = hypot(vector.dx, vector.dy)
        guard current > length, current > 0 else {
            return vector
        }
        return vector * (length / current)
    }
}

/// 札の姿勢（回転・傾き・光の向き）
struct SwipePose {
    var rotation: Angle
    var tilt: Angle
    /// 傾ける軸（札の面の中）
    var axis: CGVector
    /// 傾いた向きと強さ（大きさは 0〜1）。光の位置に使う
    var lean: CGVector

    static let flat = Self(rotation: .zero, tilt: .zero, axis: CGVector(dx: 0, dy: 1), lean: .zero)

    init(rotation: Angle, tilt: Angle, axis: CGVector, lean: CGVector) {
        self.rotation = rotation
        self.tilt = tilt
        self.axis = axis
        self.lean = lean
    }

    init(offset: CGSize, velocity: CGSize, grab: UnitPoint) {
        rotation = SwipeFeelGeometry.rotation(offset: offset, grab: grab)
        let lean = SwipeFeelGeometry.lean(offset: offset, velocity: velocity)
        let degrees = hypot(lean.dx, lean.dy)
        tilt = .degrees(degrees)
        // 右へ向かうときは縦の軸で右の縁を奥へ、上へ向かうときは横の軸で上の縁を奥へ倒す
        // （`rotation3DEffect` は、軸 (0, 1) を正の角度で回すと右の縁が奥へ、軸 (1, 0) では上の縁が奥へ下がる。Simulator の静止画で確かめた）
        axis = degrees > 0.01 ? CGVector(dx: -lean.dy / degrees, dy: lean.dx / degrees) : CGVector(dx: 0, dy: 1)
        self.lean = lean / SwipeFeelMotion.maxTilt
    }
}

/// 指を離した後の札の動き（戻る・飛ぶ）。離した速さを初速にして、いつの位置も計算で求める
/// （SwiftUI のアニメーションは初速を 1 つの数でしか渡せず、斜めの速さを引き継げないため。途中で札をつかみ直したときの位置も分かる）
struct SwipeThrow: Equatable {
    enum Kind: Equatable {
        /// 2 次元のばね（決めずに戻る・自由回答の選択肢で止める）
        case spring(Spring)
        /// 決めた札が飛んでいく。離した速さで飛び出し、`duration` で行き先に着くように足りない分だけ一定に加速する
        case fling(duration: TimeInterval)
    }

    var from: CGSize
    var to: CGSize
    /// 初速（pt/秒）
    var velocity: CGSize
    var kind: Kind
    var start: Date

    init(from: CGSize, to: CGSize, velocity: CGSize, spring: Spring, start: Date = .now) {
        self.init(from: from, to: to, velocity: velocity, kind: .spring(spring), start: start)
    }

    init(from: CGSize, to: CGSize, velocity: CGSize, kind: Kind, start: Date = .now) {
        self.from = from
        self.to = to
        self.velocity = velocity
        self.kind = kind
        self.start = start
    }

    private var delta: AnimatablePair<CGFloat, CGFloat> {
        AnimatablePair(to.width - from.width, to.height - from.height)
    }

    private var initialVelocity: AnimatablePair<CGFloat, CGFloat> {
        AnimatablePair(velocity.width, velocity.height)
    }

    /// 止まる（行き先に着く）までの時間。ばねは 0.5pt より近くなるまで
    var duration: TimeInterval {
        switch kind {
        case .spring(let spring):
            spring.settlingDuration(target: delta, initialVelocity: initialVelocity, epsilon: 0.5)

        case .fling:
            flight.duration
        }
    }

    func offset(at date: Date) -> CGSize {
        switch kind {
        case .spring(let spring):
            let moved = spring.value(target: delta, initialVelocity: initialVelocity, time: elapsed(date))
            return CGSize(width: from.width + moved.first, height: from.height + moved.second)

        case .fling:
            let fling = flight
            let time = min(elapsed(date), fling.duration)
            let along = fling.speed * time + fling.acceleration * time * time / 2
            return CGSize(
                width: from.width + fling.direction.dx * along + fling.side.dx * time,
                height: from.height + fling.direction.dy * along + fling.side.dy * time
            )
        }
    }

    func velocity(at date: Date) -> CGSize {
        switch kind {
        case .spring(let spring):
            let velocity = spring.velocity(target: delta, initialVelocity: initialVelocity, time: elapsed(date))
            return CGSize(width: velocity.first, height: velocity.second)

        case .fling:
            let fling = flight
            let speed = fling.speed + fling.acceleration * min(elapsed(date), fling.duration)
            return CGSize(width: fling.direction.dx * speed + fling.side.dx, height: fling.direction.dy * speed + fling.side.dy)
        }
    }

    /// 飛んでいく札の、行き先への向き・初めの速さ・加速・横へ流れる速さ・着くまでの時間
    private struct Flight {
        var direction: CGVector
        var speed: CGFloat
        var acceleration: CGFloat
        var side: CGVector
        var duration: TimeInterval
    }

    private var flight: Flight {
        let distance = max(hypot(delta.first, delta.second), 1)
        let direction = CGVector(dx: delta.first / distance, dy: delta.second / distance)
        let speed = max(velocity.width * direction.dx + velocity.height * direction.dy, 1)
        let side = CGVector(dx: velocity.width - direction.dx * speed, dy: velocity.height - direction.dy * speed)
        guard case .fling(let duration) = kind, speed * duration < distance else {
            // 行き先まで加速しなくても着く速さなら、そのままの速さで飛ぶ
            return Flight(direction: direction, speed: speed, acceleration: 0, side: side, duration: distance / speed)
        }
        let acceleration = 2 * (distance - speed * duration) / (duration * duration)
        return Flight(direction: direction, speed: speed, acceleration: acceleration, side: side, duration: duration)
    }

    private func elapsed(_ date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(start))
    }
}

/// 一番上の札の、スワイプしている間の動きの状態
struct SwipeCardMotion: Equatable {
    /// 指が触れている（持ち上げている）
    var isHeld = false
    /// つかんだ所（札の中の位置）。回転と傾きの軸にする
    var grab = UnitPoint.center
    /// 今回のドラッグを始めたときの札の位置（戻る途中でつかみ直したとき）
    var base = CGSize.zero
    /// 最後に測った指の速さと、その時刻（指を止めると、速さの傾きは消えていく）
    var velocity = CGSize.zero
    var velocityTime = Date.distantPast
    /// 離した後の動き
    var thrown: SwipeThrow?
    /// 離したときの速さ（決めた札を飛ばすときに使う）
    var releaseVelocity = CGSize.zero
    /// 決まる量を超えて手応えを鳴らした回数と、もう一度鳴らせるか
    var detents = 0
    var isDetentArmed = true

    /// 時間を追って描き直す必要があるか（持ち上げている間は、速さの傾きが消えていくのを描く）
    var isAnimating: Bool {
        isHeld || thrown != nil
    }

    func offset(at date: Date, resting: CGSize) -> CGSize {
        thrown?.offset(at: date) ?? resting
    }

    func velocity(at date: Date) -> CGSize {
        if let thrown {
            return thrown.velocity(at: date)
        }
        guard isHeld else {
            return .zero
        }
        let fade = exp(-max(0, date.timeIntervalSince(velocityTime)) / SwipeFeelMotion.swayDecay)
        return CGSize(width: velocity.width * fade, height: velocity.height * fade)
    }
}

private extension CGVector {
    static func * (vector: CGVector, scale: CGFloat) -> CGVector {
        CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    static func / (vector: CGVector, scale: CGFloat) -> CGVector {
        CGVector(dx: vector.dx / scale, dy: vector.dy / scale)
    }

    static func + (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }
}
