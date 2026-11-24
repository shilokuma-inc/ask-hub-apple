@testable import AskHub
import Foundation
import Testing

/// 経った時間と、Mac の最後の印の書き方（ほかの文と同じく、数と単位の間を空ける）
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func durationSeparatesNumberAndUnit() {
        #expect(RelativeTime.duration(since: now.addingTimeInterval(-22 * 60), now: now) == "22 分")
        #expect(RelativeTime.duration(since: now.addingTimeInterval(-3 * 3_600), now: now) == "3 時間")
        #expect(RelativeTime.duration(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2 日")
        // 1 分より短くても 1 分と書く
        #expect(RelativeTime.duration(since: now, now: now) == "1 分")
    }

    @Test
    func macLastSeenSaysWhenItWasChecked() {
        #expect(ConnectionBadge.checked(now.addingTimeInterval(-10), now: now) == "たった今確認")
        #expect(ConnectionBadge.checked(now.addingTimeInterval(-16 * 60), now: now) == "16 分前に確認")
    }
}
