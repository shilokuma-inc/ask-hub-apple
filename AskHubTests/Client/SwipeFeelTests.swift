@testable import AskHub
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// スワイプしている間の新しい動きの計算（ゴムの抵抗・回転と傾きの向き・離した後のばね）
@MainActor
struct SwipeFeelTests {
    private let twoChoices = SwipeLayout.directions(count: 2, hand: .right)
    private let fourChoices = SwipeLayout.directions(count: 4, hand: .right)

    /// 選択肢のある向きへは、指に 1:1 で付いてくる
    @Test
    func followsFingerTowardChoices() {
        let toward = CGSize(width: 100, height: -100)
        #expect(SwipeFeelGeometry.rubberBand(toward, directions: twoChoices) == toward)
        // 4 択はどの向きにも選択肢がある
        let sideways = CGSize(width: -140, height: 10)
        #expect(SwipeFeelGeometry.rubberBand(sideways, directions: fourChoices) == sideways)
    }

    /// 選択肢の無い向きへは、ゴムのように抵抗して、どれだけ引いても決まる量まで届かない
    @Test
    func resistsTowardMissingChoices() {
        let pulled = CGSize(width: -300, height: -300)
        let moved = SwipeFeelGeometry.rubberBand(pulled, directions: twoChoices)
        #expect(hypot(moved.width, moved.height) < SwipeLayout.commitDistance)
        // 向きは変えない
        #expect(abs(moved.width / moved.height - 1) < 0.0001)
    }

    /// 選べる向きの境目（2 択なら ↗ から 60°）では、まだ 1:1 で付いてくる（色が付き始める所で急に重くならない）
    @Test
    func followsFingerAtChoiceBoundary() {
        let angle = -Double.pi / 4 + Double.pi / 3
        let boundary = CGSize(width: 100 * cos(angle), height: -100 * sin(-angle))
        let moved = SwipeFeelGeometry.rubberBand(boundary, directions: twoChoices)
        #expect(abs(moved.width - boundary.width) < 0.01)
        #expect(abs(moved.height - boundary.height) < 0.01)
    }

    /// 上をつかんで右へ動かすと時計回り、下をつかむと反時計回り、真ん中ではほとんど回らない
    @Test
    func rotatesAroundGrabbedPoint() {
        let right = CGSize(width: 100, height: 0)
        #expect(SwipeFeelGeometry.rotation(offset: right, grab: UnitPoint(x: 0.5, y: 0.1)).degrees > 0)
        #expect(SwipeFeelGeometry.rotation(offset: right, grab: UnitPoint(x: 0.5, y: 0.9)).degrees < 0)
        #expect(SwipeFeelGeometry.rotation(offset: right, grab: .center).degrees == 0)
        // 右の端をつかんで上へ動かすと、左が遅れて反時計回り
        #expect(SwipeFeelGeometry.rotation(offset: CGSize(width: 0, height: -100), grab: UnitPoint(x: 0.9, y: 0.5)).degrees < 0)
    }

    /// 回りすぎない
    @Test
    func limitsRotation() {
        let far = SwipeFeelGeometry.rotation(offset: CGSize(width: 2_000, height: 0), grab: .top)
        #expect(far.degrees == SwipeFeelMotion.maxRotation)
    }

    /// 向かう先へ傾き、決まる量まで動かすと `restingTilt`、速く動かしても `maxTilt` を超えない
    @Test
    func leansTowardDestination() {
        let atThreshold = SwipeFeelGeometry.lean(offset: CGSize(width: SwipeLayout.commitDistance, height: 0), velocity: .zero)
        #expect(abs(atThreshold.dx - SwipeFeelMotion.restingTilt) < 0.0001)
        #expect(atThreshold.dy == 0)
        let flung = SwipeFeelGeometry.lean(offset: CGSize(width: 500, height: -500), velocity: CGSize(width: 4_000, height: -4_000))
        #expect(hypot(flung.dx, flung.dy) <= SwipeFeelMotion.maxTilt + 0.0001)
        #expect(flung.dx > 0)
        #expect(flung.dy < 0)
    }

    /// 傾ける軸。右へ向かうと縦の軸、上へ向かうと横の軸（`rotation3DEffect` の正の角度で、向かう先の縁が奥へ下がる向き）
    @Test
    func tiltAxisFollowsLean() {
        let right = SwipePose(offset: CGSize(width: 100, height: 0), velocity: .zero, grab: .center)
        #expect(abs(right.axis.dx) < 0.0001)
        #expect(abs(right.axis.dy - 1) < 0.0001)
        let up = SwipePose(offset: CGSize(width: 0, height: -100), velocity: .zero, grab: .center)
        #expect(abs(up.axis.dx - 1) < 0.0001)
        #expect(abs(up.axis.dy) < 0.0001)
        #expect(SwipePose(offset: .zero, velocity: .zero, grab: .center).tilt.degrees == 0)
    }

    /// 離した後のばねは、離した所から離した速さで動き始め、止まるころには行き先に着いている
    @Test
    func throwStartsWithReleaseVelocityAndSettlesAtTarget() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let thrown = SwipeThrow(
            from: CGSize(width: 90, height: -60),
            to: .zero,
            velocity: CGSize(width: 800, height: -300),
            spring: SwipeFeelMotion.returnSpring(speed: 854),
            start: start
        )
        #expect(thrown.offset(at: start) == CGSize(width: 90, height: -60))
        let initial = thrown.velocity(at: start)
        #expect(abs(initial.width - 800) < 1)
        #expect(abs(initial.height + 300) < 1)
        // 最初は離した向きへ進む（すぐに戻り始めない）
        let soon = thrown.offset(at: start.addingTimeInterval(0.01))
        #expect(soon.width > 90)
        let settled = thrown.offset(at: start.addingTimeInterval(thrown.duration))
        #expect(hypot(settled.width, settled.height) < 1)
    }

    /// 決めた札は、ゆっくり離すと離した速さで飛び出してから加速して、決めた時間で行き先に着く。
    /// 強く弾いたときは加速せず、その速さのまま早く着く
    @Test
    func flingKeepsReleaseSpeedAndAcceleratesOnlyWhenSlow() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        let target = CGSize(width: 537, height: -537)
        let fling = SwipeThrow.Kind.fling(duration: 0.24)
        let slow = SwipeThrow(from: .zero, to: target, velocity: CGSize(width: 354, height: -354), kind: fling, start: start)
        #expect(abs(slow.velocity(at: start).width - 354) < 1)
        #expect(abs(slow.duration - 0.24) < 0.0001)
        let arrived = slow.offset(at: start.addingTimeInterval(0.24))
        #expect(abs(arrived.width - target.width) < 0.5)
        #expect(slow.velocity(at: start.addingTimeInterval(0.2)).width > 354)

        let fast = SwipeThrow(from: .zero, to: target, velocity: CGSize(width: 3_000, height: -3_000), kind: fling, start: start)
        #expect(fast.duration < 0.24)
        #expect(abs(fast.velocity(at: start.addingTimeInterval(0.1)).width - 3_000) < 1)
        let fastArrived = fast.offset(at: start.addingTimeInterval(fast.duration))
        #expect(abs(fastArrived.width - target.width) < 0.5)
    }

    /// 決めた札は、ゆっくり離しても `launchSpeed` より遅くは飛び出さず、速く弾けばその速さのまま飛ぶ
    @Test
    func launchesAtLeastAtLaunchSpeed() {
        let delta = CGSize(width: 500, height: -500)
        let slow = SwipeFeelGeometry.launchVelocity(release: CGSize(width: 50, height: -50), toward: delta)
        #expect(abs(hypot(slow.width, slow.height) - SwipeFeelMotion.launchSpeed) < 1)
        let fast = SwipeFeelGeometry.launchVelocity(release: CGSize(width: 2_000, height: -2_000), toward: delta)
        #expect(abs(hypot(fast.width, fast.height) - 2_000 * 2.0.squareRoot()) < 1)
        // 横への速さは、向かう先への速さの半分までしか残さない
        let sideways = SwipeFeelGeometry.launchVelocity(release: CGSize(width: 3_000, height: 3_000), toward: delta)
        let along = (sideways.width - sideways.height) / 2.0.squareRoot()
        let side = (sideways.width + sideways.height) / 2.0.squareRoot()
        #expect(abs(side) <= along * 0.5 + 1)
    }

    /// 離したときの予測の位置は、DragGesture と同じく速さの 0.25 秒分を足す
    @Test
    func predictsEndLikeDragGesture() {
        let value = SwipeDragValue(translation: CGSize(width: 40, height: -40), velocity: CGSize(width: 400, height: -200))
        #expect(value.predictedEndTranslation == CGSize(width: 140, height: -90))
    }

    /// 指を止めると、速さの傾きは消えていく。指を離していれば速さは 0
    @Test
    func swayFadesWhenFingerStops() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        var motion = SwipeCardMotion()
        motion.isHeld = true
        motion.velocity = CGSize(width: 1_000, height: 0)
        motion.velocityTime = now
        #expect(motion.velocity(at: now).width == 1_000)
        #expect(motion.velocity(at: now.addingTimeInterval(0.3)).width < 50)
        motion.isHeld = false
        #expect(motion.velocity(at: now) == .zero)
    }
}
