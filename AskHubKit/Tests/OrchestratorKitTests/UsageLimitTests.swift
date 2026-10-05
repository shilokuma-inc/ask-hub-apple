import Foundation
@testable import OrchestratorKit
import Testing

struct UsageLimitTests {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// 東京の `day` 日 `hour`:`minute`（2026 年 10 月）
    private func tokyoDate(day: Int, hour: Int, minute: Int = 0, month: Int = 10, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func readsSessionLimitResetLaterSameDay() {
        let output = "作業の途中\nYou've hit your session limit · resets 12pm (Asia/Tokyo)\n"
        #expect(UsageLimit.resetDate(in: output, loggedAt: tokyoDate(day: 5, hour: 10, minute: 11)) == tokyoDate(day: 5, hour: 12))
    }

    @Test func rollsTimeOnlyResetToNextDayWhenAlreadyPassed() {
        let output = "You've hit your session limit · resets 5:30am (Asia/Tokyo)"
        #expect(UsageLimit.resetDate(in: output, loggedAt: tokyoDate(day: 5, hour: 23)) == tokyoDate(day: 6, hour: 5, minute: 30))
    }

    @Test func readsResetWithDateAndYearBoundary() {
        let weekly = "You've hit your weekly limit · resets Oct 7, 9am (Asia/Tokyo)"
        #expect(UsageLimit.resetDate(in: weekly, loggedAt: tokyoDate(day: 5, hour: 10)) == tokyoDate(day: 7, hour: 9))
        let nextYear = "You've hit your weekly limit · resets Jan 2 at 3pm (Asia/Tokyo)"
        #expect(UsageLimit.resetDate(in: nextYear, loggedAt: tokyoDate(day: 30, hour: 10, month: 12))
            == tokyoDate(day: 2, hour: 15, month: 1, year: 2027))
    }

    @Test func readsEpochFormAndFallsBackWhenTimeIsUnreadable() {
        let loggedAt = tokyoDate(day: 5, hour: 10)
        let reset = loggedAt.addingTimeInterval(2 * 60 * 60)
        let epoch = UsageLimit.resetDate(in: "Claude AI usage limit reached|\(Int(reset.timeIntervalSince1970))", loggedAt: loggedAt)
        #expect(epoch == reset)
        // ミリ秒の UNIX 時刻（桁違いに先の時刻）は読めなかったものとみなす
        let milliseconds = UsageLimit.resetDate(in: "Claude AI usage limit reached|1800000000000", loggedAt: loggedAt)
        #expect(milliseconds == loggedAt.addingTimeInterval(60 * 60))
        // 解除の時刻を読めなければ、1 時間後に試し直す
        #expect(UsageLimit.resetDate(in: "You've hit your usage limit", loggedAt: loggedAt) == loggedAt.addingTimeInterval(60 * 60))
        // タイムゾーンが無ければ、既定のタイムゾーンで読む
        #expect(UsageLimit.resetDate(in: "You've hit your session limit · resets 12pm", loggedAt: loggedAt, timeZone: tokyo)
            == tokyoDate(day: 5, hour: 12))
    }

    @Test func ignoresOutputThatDidNotEndWithLimit() {
        let loggedAt = tokyoDate(day: 5, hour: 10)
        #expect(UsageLimit.resetDate(in: "ビルドが通りました\n<promise>DONE</promise>", loggedAt: loggedAt) == nil)
        // 上限の話をしていても、上限で終わったのでなければ待たない（末尾の数行だけを見る）
        let earlier = "You've hit your session limit · resets 12pm (Asia/Tokyo)\n" + (1...10).map { "行 \($0)" }.joined(separator: "\n")
        #expect(UsageLimit.resetDate(in: earlier, loggedAt: loggedAt) == nil)
    }
}
