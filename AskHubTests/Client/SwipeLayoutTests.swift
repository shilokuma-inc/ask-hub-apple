@testable import AskHub
import CoreGraphics
import Testing

/// スワイプの方向の割り当てと判定（推奨はいつも利き手側の上・右手の 3 択は ↘ を使わない）
@MainActor
struct SwipeLayoutTests {
    /// 右手の割り当て
    @Test(arguments: [
        (2, [SwipeDirection.upRight, .downLeft]),
        (3, [SwipeDirection.upRight, .upLeft, .downLeft]),
        (4, [SwipeDirection.upRight, .upLeft, .downLeft, .downRight])
    ])
    func rightHandDirections(count: Int, expected: [SwipeDirection]) {
        #expect(SwipeLayout.directions(count: count, hand: .right) == expected)
    }

    /// 左手は鏡写し
    @Test(arguments: [
        (2, [SwipeDirection.upLeft, .downRight]),
        (3, [SwipeDirection.upLeft, .upRight, .downRight]),
        (4, [SwipeDirection.upLeft, .upRight, .downRight, .downLeft])
    ])
    func leftHandMirrorsRightHand(count: Int, expected: [SwipeDirection]) {
        #expect(SwipeLayout.directions(count: count, hand: .left) == expected)
    }

    /// 推奨はいつも先頭の方向
    @Test
    func recommendedAlwaysTakesFirstDirection() {
        for count in 1...4 {
            #expect(SwipeLayout.directions(count: count, hand: .right).first == .upRight)
            #expect(SwipeLayout.directions(count: count, hand: .left).first == .upLeft)
        }
    }

    /// 短い動きはどの方向にも数えない
    @Test
    func ignoresShortMoves() {
        let directions = SwipeLayout.directions(count: 3, hand: .right)
        #expect(SwipeLayout.candidate(for: CGSize(width: 5, height: -5), directions: directions) == nil)
    }

    /// 斜めに動かした方向の選択肢になる
    @Test
    func picksChoiceOfDiagonalMove() {
        let directions = SwipeLayout.directions(count: 3, hand: .right)
        #expect(SwipeLayout.candidate(for: CGSize(width: 80, height: -60), directions: directions) == 0)
        #expect(SwipeLayout.candidate(for: CGSize(width: -70, height: -90), directions: directions) == 1)
        #expect(SwipeLayout.candidate(for: CGSize(width: -80, height: 70), directions: directions) == 2)
    }

    /// 使わない方向に動かしても選ばない
    @Test
    func ignoresUnusedDirection() {
        // 右手の 3 択は ↘ を使わない
        let directions = SwipeLayout.directions(count: 3, hand: .right)
        #expect(SwipeLayout.candidate(for: CGSize(width: 90, height: 90), directions: directions) == nil)
    }

    /// 一定の量を超えて離すと決まる
    @Test
    func commitsBeyondDistanceOrFlick() {
        #expect(!SwipeLayout.commits(translation: CGSize(width: 50, height: -50), predictedEnd: CGSize(width: 60, height: -60)))
        #expect(SwipeLayout.commits(translation: CGSize(width: 90, height: -90), predictedEnd: CGSize(width: 90, height: -90)))
        // 勢いよく弾いたときも決める
        #expect(SwipeLayout.commits(translation: CGSize(width: 40, height: -40), predictedEnd: CGSize(width: 200, height: -200)))
    }

    /// 進み具合は決まる量で1になる
    @Test
    func progressReachesOneAtCommitDistance() {
        #expect(SwipeLayout.progress(for: .zero) == 0)
        #expect(SwipeLayout.progress(for: CGSize(width: SwipeLayout.commitDistance * 2, height: 0)) == 1)
    }

    /// 色の濃さは動かすほど濃くなりほかは薄くなる
    @Test
    func intensityGrowsTowardCandidate() {
        let rest = SwipeIntensity.opacity(index: 0, drag: SwipeDragState())
        let toward = SwipeIntensity.opacity(index: 0, drag: SwipeDragState(candidate: 0, progress: 1))
        let other = SwipeIntensity.opacity(index: 1, drag: SwipeDragState(candidate: 0, progress: 1))
        #expect(rest == SwipeIntensity.rest)
        #expect(toward == SwipeIntensity.max)
        #expect(other < rest)
    }
}
