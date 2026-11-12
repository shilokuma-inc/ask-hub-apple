@testable import AskHub
import Foundation
import Testing

/// まとめて判断するの札の大きさ。iPhone では今の縦長のまま、Mac・iPad の広い場所では縦に伸ばしすぎない
struct DeckCardSizeTests {
    /// iPhone の幅（iPhone 13・17 Pro・Pro Max）では、幅の 1.55 倍の縦長のまま
    @Test(arguments: [CGFloat(390), 402, 440])
    func iPhoneKeepsTallCard(width: CGFloat) {
        let size = DecisionDeckView.cardSize(in: CGSize(width: width, height: 2_000))
        #expect(abs(size.width - (width - 44)) < 0.01)
        #expect(abs(size.height - size.width * 1.55) < 0.01)
    }

    /// 広い場所では幅 440 で止め、高さは幅の 1.25 倍まで
    @Test
    func wideAreaLimitsHeight() {
        let size = DecisionDeckView.cardSize(in: CGSize(width: 900, height: 2_000))
        #expect(abs(size.width - 440) < 0.01)
        #expect(abs(size.height - 550) < 0.01)
    }

    /// 窓の幅を変えても、札の高さが跳ねずに少しずつ変わる
    @Test
    func heightChangesSmoothly() {
        let heights = stride(from: CGFloat(430), through: 600, by: 1).map { width in
            DecisionDeckView.cardSize(in: CGSize(width: width, height: 2_000)).height
        }
        let jumps = zip(heights, heights.dropFirst()).map { abs($1 - $0) }
        #expect(jumps.allSatisfy { $0 < 6 })
    }

    /// 高さは置ける場所を超えない
    @Test
    func heightFitsAvailableArea() {
        let size = DecisionDeckView.cardSize(in: CGSize(width: 900, height: 400))
        #expect(abs(size.height - 336) < 0.01)
    }
}
