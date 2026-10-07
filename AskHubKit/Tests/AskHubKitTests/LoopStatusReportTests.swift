@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var running: LoopStatusReport {
        LoopStatusReport(
            state: .running,
            epic: "epic/loop-status",
            discussion: 197,
            progress: .init(completed: 5, total: 12),
            lastActivityAt: now.addingTimeInterval(-180),
            checkedAt: now
        )
    }

    @Test func roundTripsIssueBody() {
        #expect(LoopStatusReport.parse(running.issueBody) == running)

        let limited = LoopStatusReport(
            state: .usageLimited, epic: "epic/x", usageLimitedUntil: now.addingTimeInterval(3600), checkedAt: now
        )
        #expect(LoopStatusReport.parse(limited.issueBody) == limited)

        let noLoop = LoopStatusReport(state: .noLoop, checkedAt: now)
        #expect(LoopStatusReport.parse(noLoop.issueBody) == noLoop)
    }

    @Test func roundTripsEveryState() {
        for state in LoopStatusReport.State.allCases where state != .unknown {
            let report = LoopStatusReport(state: state, checkedAt: now)
            #expect(LoopStatusReport.parse(report.issueBody)?.state == state)
        }
    }

    @Test func writesMarkerFirstAndReadableTable() {
        let body = running.issueBody
        #expect(body.hasPrefix(#"<!-- ask-hub:loop-status {"checkedAt":"#))
        #expect(body.contains("| 状態 | 実行中 |"))
        #expect(body.contains("| epic | epic/loop-status |"))
        #expect(body.contains("| ゴール元 | Discussion #197 |"))
        #expect(body.contains("| 進捗 | 5 / 12 タスク完了 |"))
        #expect(body.contains("| 最後の動き | "))
        #expect(!body.contains("上限の解除"))
    }

    @Test func decodesProgressWithAndWithoutDeferredCount() {
        // 古いオーケストレーターは `deferred` を書かない
        let old = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","#
            + #""progress":{"completed":5,"total":12},"state":"running"} -->"#
        #expect(LoopStatusReport.parse(old)?.progress == .init(completed: 5, total: 12))
        #expect(LoopStatusReport.parse(old)?.progress?.deferred == nil)

        let new = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","#
            + #""progress":{"completed":5,"deferred":2,"total":12},"state":"running"} -->"#
        #expect(LoopStatusReport.parse(new)?.progress == .init(completed: 5, total: 12, deferred: 2))
    }

    @Test func writesDeferredCountOnlyWhenKnown() {
        var report = running
        #expect(!report.issueBody.contains("deferred"))
        report.progress = .init(completed: 5, total: 12, deferred: 2)
        let body = report.issueBody
        #expect(body.contains(#""progress":{"completed":5,"deferred":2,"total":12}"#))
        #expect(body.contains("| 進捗 | 5 / 12 タスク完了（うち保留 2） |"))
        #expect(LoopStatusReport.parse(body) == report)

        // 保留が 0 件なら表は今と同じ
        report.progress = .init(completed: 5, total: 12, deferred: 0)
        #expect(report.issueBody.contains("| 進捗 | 5 / 12 タスク完了 |"))
        #expect(LoopStatusReport.parse(report.issueBody) == report)
    }

    @Test func keepsMarkerIntactWhenValuesContainCommentClose() {
        let report = LoopStatusReport(state: .running, epic: "epic/a-->b|c\nd", checkedAt: now)
        let body = report.issueBody
        // 目印の閉じ（`-->`）は最初の行の末尾だけ
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLine.components(separatedBy: "-->").count == 2)
        #expect(LoopStatusReport.parse(body) == report)
        #expect(body.contains(#"| epic | epic/a-->b\|c d |"#))
    }

    @Test func truncatesFractionalSecondsSoParsedReportsCompareEqual() {
        let report = LoopStatusReport(
            state: .running, lastActivityAt: now.addingTimeInterval(0.7), checkedAt: now.addingTimeInterval(0.4)
        )
        #expect(report.checkedAt == now)
        #expect(LoopStatusReport.parse(report.issueBody) == report)

        // 作った後に代入した時刻も切り捨てる
        var updated = report
        updated.checkedAt = now.addingTimeInterval(600.9)
        updated.lastActivityAt = now.addingTimeInterval(300.5)
        updated.usageLimitedUntil = now.addingTimeInterval(3600.2)
        #expect(updated.checkedAt == now.addingTimeInterval(600))
        #expect(updated.lastActivityAt == now.addingTimeInterval(300))
        #expect(updated.usageLimitedUntil == now.addingTimeInterval(3600))
        #expect(LoopStatusReport.parse(updated.issueBody) == updated)
    }

    @Test func comparesStatusIgnoringCheckedAt() {
        var later = running
        later.checkedAt = now.addingTimeInterval(600)
        #expect(running.hasSameStatus(as: later))
        #expect(running != later)

        var progressed = later
        progressed.progress = .init(completed: 6, total: 12)
        #expect(!running.hasSameStatus(as: progressed))
    }

    @Test func readsUnknownStatesAndIgnoresUnknownKeys() {
        let body = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","state":"paused","extra":1} -->"#
        let report = LoopStatusReport.parse(body)
        #expect(report?.state == .unknown)
        #expect(report?.checkedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func roundTripsWriter() {
        #expect(running.writer == .orchestrator)
        #expect(running.issueBody.contains(#""writer":"orchestrator""#))
        #expect(running.issueBody.contains("| 書き手 | オーケストレーター |"))

        let manual = LoopStatusReport(state: .running, writer: .manual, epic: "epic/manual-loop", checkedAt: now)
        let body = manual.issueBody
        #expect(body.contains(#""writer":"manual""#))
        #expect(body.contains("| 書き手 | 手動 |"))
        #expect(body.contains("手で回しているループが書き換える Issue です。"))
        #expect(LoopStatusReport.parse(body) == manual)
        #expect(!manual.hasSameStatus(as: running))
    }

    @Test func readsMarkersWithoutWriterAsOrchestrator() {
        // `writer` を足す前のオーケストレーターが書いた目印
        let body = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","epic":"epic/x","state":"running"} -->"#
        let report = LoopStatusReport.parse(body)
        #expect(report?.writer == .orchestrator)
        #expect(report?.epic == "epic/x")
    }

    @Test func readsUnknownWriters() {
        let body = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","state":"running","writer":"robot"} -->"#
        let report = LoopStatusReport.parse(body)
        #expect(report?.writer == .unknown)
        // 書き直しても、オーケストレーターが書いたとは表示しない
        #expect(report?.issueBody.contains("| 書き手 | 不明 |") == true)
        #expect(report?.issueBody.contains("AskHub のループ（書き手は不明）が書き換える Issue です。") == true)
    }

    @Test func rejectsBodiesWithoutMarker() {
        #expect(LoopStatusReport.parse("") == nil)
        #expect(LoopStatusReport.parse("人が書いた本文") == nil)
        // 目印が先頭に無い
        #expect(LoopStatusReport.parse("前置き\n" + running.issueBody) == nil)
        // 別の語
        #expect(LoopStatusReport.parse(#"<!-- ask-hub:loop-statuses {"checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#) == nil)
        #expect(LoopStatusReport.parse(#"<!-- ask-hub:loop-status{"checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#) == nil)
        // 必須の項目が無い・JSON が崩れている・閉じが無い
        #expect(LoopStatusReport.parse(#"<!-- ask-hub:loop-status {"state":"running"} -->"#) == nil)
        #expect(LoopStatusReport.parse("<!-- ask-hub:loop-status {state -->") == nil)
        #expect(LoopStatusReport.parse(#"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","state":"running"}"#) == nil)
        // 先頭の空白・改行は無視する
        #expect(LoopStatusReport.parse("\n  " + running.issueBody) == running)
    }

    @Test func assignedOnlyWhileCheckedRecently() {
        #expect(running.isAssigned(now: now.addingTimeInterval(29 * 60)))
        #expect(!running.isAssigned(now: now.addingTimeInterval(31 * 60)))
    }

    @Test func bodyHoldsNoLocalPaths() {
        let body = running.issueBody
        #expect(!body.contains("/Users/"))
        #expect(!body.contains(".claude/"))
        #expect(!body.contains(".local."))
    }
}
