@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let issueURL = URL(string: "https://github.com/o/r/issues/3")!

    private func row(_ report: LoopStatusReport?, lastSeen: Date? = nil, issueURL: URL? = nil) -> LoopStatusRow {
        LoopStatusRow(repository: "o/r", report: report, issueURL: issueURL, lastSeen: lastSeen)
    }

    private func report(
        _ state: LoopStatusReport.State,
        discussion: Int? = nil,
        lastActivityMinutesAgo: Double? = nil,
        usageLimitedUntil: Date? = nil
    ) -> LoopStatusReport {
        LoopStatusReport(
            state: state,
            epic: "epic/loop-status",
            discussion: discussion,
            progress: .init(completed: 5, total: 12),
            lastActivityAt: lastActivityMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
            usageLimitedUntil: usageLimitedUntil,
            checkedAt: now
        )
    }

    @Test func showsReportedFields() {
        let display = row(report(.running, discussion: 12, lastActivityMinutesAgo: 3), issueURL: issueURL).display(now: now)
        #expect(display.statusText == "実行中")
        #expect(display.systemImage == "play.circle.fill")
        #expect(display.tone == .active)
        #expect(display.epic == "epic/loop-status")
        #expect(display.discussionText == "ゴール元: Discussion #12")
        #expect(display.progressText == "5 / 12 タスク完了")
        #expect(display.lastActivityAt == now.addingTimeInterval(-3 * 60))
        #expect(!display.isStuck)
        // ゴール元の Discussion を優先して開く
        #expect(display.destination == URL(string: "https://github.com/o/r/discussions/12"))
    }

    @Test func opensStatusIssueWithoutDiscussion() {
        #expect(row(report(.noLoop), issueURL: issueURL).display(now: now).destination == issueURL)
        #expect(row(report(.noLoop)).display(now: now).destination == nil)
        #expect(row(report(.noLoop)).display(now: now).discussionText == nil)
    }

    @Test func describesUnassignedAndNotReported() {
        let unassigned = row(nil).display(now: now)
        #expect(unassigned.statusText == "担当 PC なし")
        #expect(unassigned.tone == .inactive)
        #expect(unassigned.epic == nil)
        #expect(unassigned.progressText == nil)
        // 古い状態にゴール元があっても、出していないので開くのは状態用の Issue
        var stale = report(.running, discussion: 12)
        stale.checkedAt = now.addingTimeInterval(-60 * 60)
        let staleDisplay = row(stale, issueURL: issueURL).display(now: now)
        #expect(staleDisplay.statusText == "担当 PC なし")
        #expect(staleDisplay.discussionText == nil)
        #expect(staleDisplay.destination == issueURL)

        let notReported = row(nil, lastSeen: now).display(now: now)
        #expect(notReported.statusText == "状態なし")
        #expect(notReported.tone == .inactive)
        #expect(notReported.systemImage != unassigned.systemImage)
    }

    @Test func appendsResumeTimeWhileUsageLimited() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10, minute: 11))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 12))!
        let limited = LoopStatusRow(
            repository: "o/r",
            report: LoopStatusReport(state: .usageLimited, usageLimitedUntil: noon, checkedAt: morning)
        )
        let display = limited.display(now: morning, calendar: calendar)
        #expect(display.statusText == "上限で待機中（12:00 に再開）")
        #expect(display.tone == .paused)
        // 解除の時刻が無ければ状態の名前だけ
        #expect(row(report(.usageLimited)).display(now: now).statusText == "上限で待機中")
    }

    @Test func everyStateHasSymbolAndTone() {
        let displays = LoopStatusReport.State.allCases.map { row(report($0)).display(now: now) }
        #expect(displays.allSatisfy { !$0.systemImage.isEmpty })
        #expect(displays.map(\.statusText) == LoopStatusReport.State.allCases.map(\.title))
        #expect(Set(LoopStatusReport.State.allCases.map { row(report($0)).display(now: now).systemImage }).count
            == LoopStatusReport.State.allCases.count)
        #expect(row(report(.gaveUp)).display(now: now).tone == .failure)
        #expect(row(report(.completed)).display(now: now).tone == .done)
        #expect(row(report(.waitingForAnswer)).display(now: now).tone == .needsAnswer)
    }

    @Test func detectsStuckRunningLoop() {
        let threshold = LoopStatusRow.stuckThreshold / 60
        #expect(!row(report(.running, lastActivityMinutesAgo: threshold)).isStuck(now: now))
        #expect(row(report(.running, lastActivityMinutesAgo: threshold + 1)).isStuck(now: now))
        #expect(row(report(.running, lastActivityMinutesAgo: threshold + 1)).display(now: now).isStuck)
        // 最後の動きが分からなければ知らせない
        #expect(!row(report(.running)).isStuck(now: now))
        // 実行中以外は、動きが無くても知らせない
        #expect(!row(report(.waitingForAnswer, lastActivityMinutesAgo: 120)).isStuck(now: now))
        // 担当 PC がいなければ「担当 PC なし」を優先する
        var stale = report(.running, lastActivityMinutesAgo: 120)
        stale.checkedAt = now.addingTimeInterval(-60 * 60)
        #expect(!row(stale).isStuck(now: now))
    }
}
