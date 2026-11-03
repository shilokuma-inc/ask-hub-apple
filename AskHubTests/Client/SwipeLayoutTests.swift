@testable import AskHub
import CoreGraphics
import Testing

/// スワイプの方向の割り当てと判定（推奨はいつも利き手側の上・自由回答は推奨の対角・右手の 3 択は ↘ を使わない）
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

    /// 自由回答の選択肢は、推奨の対角（右手は ↙・左手は ↘）に並べ替える。ほかの選択肢は書かれた順のまま
    @Test(arguments: [
        (["推奨", "自由"], ["推奨", "自由"]),
        (["推奨", "自由", "A"], ["推奨", "A", "自由"]),
        (["推奨", "自由", "A", "B"], ["推奨", "A", "自由", "B"]),
        (["推奨", "A", "B", "自由"], ["推奨", "A", "自由", "B"])
    ])
    func freeTextGoesOppositeRecommended(items: [String], expected: [String]) throws {
        let arranged = SwipeLayout.arranged(items, asksText: Self.asksText)
        #expect(arranged == expected)
        let index = try #require(arranged.firstIndex(of: "自由"))
        #expect(SwipeLayout.directions(count: arranged.count, hand: .right)[index] == .downLeft)
        #expect(SwipeLayout.directions(count: arranged.count, hand: .left)[index] == .downRight)
    }

    /// 自由回答が無ければ並びは変えない
    @Test
    func keepsOrderWithoutFreeText() {
        for items in [["推奨"], ["推奨", "A"], ["推奨", "A", "B"], ["推奨", "A", "B", "C"]] {
            #expect(SwipeLayout.arranged(items, asksText: Self.asksText) == items)
        }
    }

    /// 自由回答が 2 つあれば、1 つ目を対角に置き、2 つ目は空いている方向に残す
    @Test
    func secondFreeTextTakesRemainingDirection() {
        #expect(SwipeLayout.arranged(["推奨", "自由1", "自由2"], asksText: Self.asksText) == ["推奨", "自由2", "自由1"])
        #expect(SwipeLayout.arranged(["推奨", "自由1", "A", "自由2"], asksText: Self.asksText) == ["推奨", "A", "自由1", "自由2"])
    }

    /// 推奨そのものが自由回答なら、推奨を優先して先頭（↗）に残す。ほかに自由回答があれば、その 1 つ目を対角に置く
    @Test
    func recommendedFreeTextStaysFirst() {
        #expect(SwipeLayout.arranged(["自由推奨"], asksText: Self.asksText) == ["自由推奨"])
        #expect(SwipeLayout.arranged(["自由推奨", "A", "B"], asksText: Self.asksText) == ["自由推奨", "A", "B"])
        #expect(SwipeLayout.arranged(["自由推奨", "自由", "A"], asksText: Self.asksText) == ["自由推奨", "A", "自由"])
    }

    /// 対角は向きどうしで対になる
    @Test
    func oppositeIsDiagonal() {
        for direction in SwipeDirection.allCases {
            #expect(direction.opposite.unit.dx == -direction.unit.dx)
            #expect(direction.opposite.unit.dy == -direction.unit.dy)
            #expect(direction.opposite.opposite == direction)
        }
    }

    private static func asksText(_ item: String) -> Bool {
        item.hasPrefix("自由")
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

    /// 数字キーは 1 から選択肢の数までだけ選べる。選択肢の無い自由記述のカードで数字を打っても落ちない
    @Test
    func choiceIndexForKeyStaysInRange() {
        #expect(SwipeLayout.choiceIndex(forKey: "2", count: 3) == 1)
        #expect(SwipeLayout.choiceIndex(forKey: "4", count: 3) == nil)
        #expect(SwipeLayout.choiceIndex(forKey: "0", count: 3) == nil)
        #expect(SwipeLayout.choiceIndex(forKey: "1", count: 0) == nil)
        #expect(SwipeLayout.choiceIndex(forKey: "a", count: 3) == nil)
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
