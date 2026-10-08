@testable import AskHubKit
import Foundation
import Testing

struct LoopOverviewTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func epic(_ repository: String, number: Int = 12, assignee: String? = "partner") -> ManualLoopEpic {
        ManualLoopEpic(
            subject: InboxSubject(
                kind: .discussion,
                nodeID: "D_\(number)",
                repository: repository,
                number: number,
                title: "依頼",
                url: URL(string: "https://github.com/\(repository)/discussions/\(number)")!,
                author: "mrs1669"
            ),
            assignee: assignee
        )
    }

    static func row(_ repository: String, report: LoopStatusReport?, lastSeen: Date? = now) -> LoopStatusRow {
        LoopStatusRow(repository: repository, report: report, lastSeen: lastSeen)
    }

    @Test func tellsWhoRunsTheLoop() {
        let manual = [Self.epic("o/manual")]
        #expect(Self.row("o/manual", report: nil).mode(manualLoops: manual) == .manual(assignee: "partner"))
        #expect(Self.row("o/auto", report: LoopStatusReport(state: .running, checkedAt: Self.now)).mode(manualLoops: manual) == .automatic)
        #expect(Self.row("o/idle", report: LoopStatusReport(state: .noLoop, checkedAt: Self.now)).mode(manualLoops: manual) == .none)
        #expect(LoopMode.manual(assignee: "partner").title == "手動ループ（@partner）")
        #expect(LoopMode.automatic.title == "自動ループ")
    }

    @Test func countsOnlyAbnormalStatuses() {
        let fresh = Self.now.addingTimeInterval(-60)
        // 異常終了
        #expect(Self.row("o/a", report: LoopStatusReport(state: .gaveUp, checkedAt: fresh)).isAbnormal(now: Self.now))
        // 実行中なのに長く動きが無い
        let stuck = LoopStatusReport(state: .running, lastActivityAt: Self.now.addingTimeInterval(-3600), checkedAt: fresh)
        #expect(Self.row("o/b", report: stuck).isAbnormal(now: Self.now))
        // 進行中の epic があるのに担当 PC がいない
        let old = Self.now.addingTimeInterval(-2 * 3600)
        #expect(Self.row("o/c", report: LoopStatusReport(state: .running, checkedAt: old), lastSeen: old).isAbnormal(now: Self.now))
        // 正常な状態・epic の無いリポジトリで担当 PC がいない（外しただけ）は数えない
        for state in [LoopStatusReport.State.running, .waitingForAnswer, .usageLimited, .waitingToStart, .completed, .noLoop] {
            #expect(!Self.row("o/d", report: LoopStatusReport(state: state, checkedAt: fresh)).isAbnormal(now: Self.now), "\(state)")
        }
        #expect(!Self.row("o/e", report: LoopStatusReport(state: .noLoop, checkedAt: old), lastSeen: old).isAbnormal(now: Self.now))
    }

    @Test func buildsManualLoopItems() {
        let waiting = LoopStatusReport(
            state: .waitingForAnswer,
            writer: .manual,
            epic: "epic/x",
            discussion: 12,
            checkedAt: Self.now.addingTimeInterval(-600),
            runner: "partner",
            waitingPullRequests: [34, 35]
        )
        let rows = [Self.row("o/r", report: waiting)]
        let epics = [Self.epic("o/r")]

        // PR #35 にまだ needs-answer が付いている
        let pending = ManualLoopItem.items(epics: epics, rows: rows, viewer: "Partner", needsAnswer: ["o/r#35"], now: Self.now)
        #expect(pending.map(\.isMine) == [true])
        #expect(pending.map(\.answersReady) == [false])
        #expect(pending.first?.statusText == "回答待ち")

        // すべての回答待ちから needs-answer が外れた
        let ready = ManualLoopItem.items(epics: epics, rows: rows, viewer: "mrs1669", needsAnswer: [], now: Self.now)
        #expect(ready.map(\.answersReady) == [true])
        #expect(ready.map(\.isMine) == [false])
    }

    @Test func flagsManualLoopThatStoppedReporting() {
        let running = LoopStatusReport(state: .running, writer: .manual, discussion: 12, checkedAt: Self.now.addingTimeInterval(-31 * 60))
        let items = ManualLoopItem.items(
            epics: [Self.epic("o/r")], rows: [Self.row("o/r", report: running)], viewer: nil, needsAnswer: [], now: Self.now
        )
        #expect(items.map(\.isStale) == [true])

        // オーケストレーターが書いた状態や、別の Discussion の状態は、この手動ループのものとして使わない
        let other = LoopStatusReport(state: .running, writer: .manual, discussion: 99, checkedAt: Self.now)
        let notStarted = ManualLoopItem.items(
            epics: [Self.epic("o/r")], rows: [Self.row("o/r", report: other)], viewer: nil, needsAnswer: [], now: Self.now
        )
        #expect(notStarted.first?.report == nil)
        #expect(notStarted.first?.statusText == "未開始")
    }

    @Test func roundTripsRunnerAndWaitingPullRequests() throws {
        let report = LoopStatusReport(
            state: .waitingForAnswer,
            writer: .manual,
            epic: "epic/x",
            discussion: 12,
            checkedAt: Self.now,
            runner: "partner",
            waitingPullRequests: [34]
        )
        let body = report.issueBody
        #expect(body.contains(#""runner":"partner""#))
        #expect(body.contains("| 回している人 | @partner |"))
        #expect(body.contains("| 回答待ちの PR | #34 |"))
        #expect(LoopStatusReport.parse(body) == report)
    }
}
