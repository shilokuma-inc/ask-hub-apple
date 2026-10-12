@testable import AskHubKit
import Foundation
import Testing

/// 同じリポジトリの複数のループを、リポジトリの見出しの下に並べる
struct LoopStatusLoopItemTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])

    private func loop(
        _ state: LoopStatusReport.State,
        writer: LoopStatusReport.Writer = .orchestrator,
        discussion: Int?,
        checkedMinutesAgo: Double = 1,
        runner: String? = nil
    ) -> LoopStatusReport {
        LoopStatusReport(
            state: state,
            writer: writer,
            epic: discussion.map { "epic/d\($0)" },
            discussion: discussion,
            checkedAt: now.addingTimeInterval(-checkedMinutesAgo * 60),
            runner: runner
        )
    }

    /// 本文（新しい形）と、ループごとのコメントを持つリポジトリの行
    private func row(
        _ loops: [LoopStatusReport], usageLimitedUntil: Date? = nil, heartbeatMinutesAgo: Double? = 1
    ) -> LoopStatusRow {
        let body = RepositoryStatusReport(usageLimitedUntil: usageLimitedUntil, checkedAt: now.addingTimeInterval(-60)).marker
        let comments = loops.enumerated().map { index, report in
            LoopStatusComment(id: index + 1, author: "mrs1669", updatedAt: now, body: report.issueBody)
        }
        let issue = LoopStatusIssue(
            number: 1, url: URL(string: "https://github.com/o/r/issues/1")!, author: "mrs1669", updatedAt: now, body: body, comments: comments
        )
        let heartbeat = heartbeatMinutesAgo.map { OrchestratorHeartbeat.description(at: now.addingTimeInterval(-$0 * 60)) }
        let repository = LoopStatusRepository(repository: "o/r", heartbeatDescription: heartbeat, issues: [issue])
        return LoopStatusRow.rows(from: [repository], trustedAuthors: trusted)[0]
    }

    private func manualEpic(_ number: Int, assignee: String?) -> ManualLoopEpic {
        ManualLoopEpic(
            subject: InboxSubject(
                kind: .discussion,
                nodeID: "D_\(number)",
                repository: "o/r",
                number: number,
                title: "手動",
                url: URL(string: "https://github.com/o/r/discussions/\(number)")!
            ),
            assignee: assignee
        )
    }

    @Test func listsAutomaticAndManualLoopsUnderRepository() {
        let automatic = loop(.running, discussion: 12)
        let manual = loop(.waitingForAnswer, writer: .manual, discussion: 30, runner: "partner")
        let items = row([manual, automatic]).loopItems(manualLoops: [manualEpic(30, assignee: "mrs1669")])

        // Discussion の番号の順。手動ループの担当者は、開いている手動ループの担当のコメントから出す
        #expect(items.map(\.id) == ["o/r#12", "o/r#30"])
        #expect(items.map(\.mode) == [.automatic, .manual(assignee: "mrs1669")])
        #expect(items.map { $0.display(now: now).statusText } == ["実行中", "回答待ち"])
        #expect(items[1].display(now: now).discussionText == "ゴール元: Discussion #30")
        #expect(items[1].display(now: now).destination == URL(string: "https://github.com/o/r/discussions/30"))

        // 担当のコメントが無ければ、状態の runner
        #expect(row([manual, automatic]).loopItems(manualLoops: [])[1].mode == .manual(assignee: "partner"))
    }

    @Test func listsTwoManualLoopsOfSameRepository() {
        let first = loop(.running, writer: .manual, discussion: 61, runner: "mrs1669")
        let second = loop(.waitingToStart, writer: .manual, discussion: 63, runner: "partner")
        let items = row([first, second]).loopItems(manualLoops: [])
        #expect(items.map(\.mode) == [.manual(assignee: "mrs1669"), .manual(assignee: "partner")])
        #expect(items.map { $0.display(now: now).epic } == ["epic/d61", "epic/d63"])
    }

    @Test func keepsSingleRowWhenRepositoryHasOneLoop() {
        // ループが 1 つ（ループなしを除いて）なら、今までと同じ 1 行で出す
        #expect(row([loop(.running, discussion: 12)]).loopItems(manualLoops: []).isEmpty)
        #expect(row([loop(.running, discussion: 12), loop(.noLoop, discussion: 9)]).loopItems(manualLoops: []).isEmpty)
        #expect(row([]).loopItems(manualLoops: []).isEmpty)
        #expect(LoopStatusRow(repository: "o/r", report: loop(.running, discussion: 12)).loopItems(manualLoops: []).isEmpty)
    }

    @Test func keepsStoppedManualLoopReportedLikeSingleRow() {
        // 回答待ち・開始待ちで止まった手動ループは確認時刻を書き直さないので、古くなっても状態を出し続ける（異常にも数えない）
        let waiting = loop(.waitingForAnswer, writer: .manual, discussion: 30, checkedMinutesAgo: 120, runner: "partner")
        let items = row([loop(.running, discussion: 12), waiting]).loopItems(manualLoops: [])
        #expect(items[1].row.status(now: now) == .reported(waiting))
        #expect(items[1].display(now: now).statusText == "回答待ち")
        #expect(!items[1].row.isAbnormal(now: now))
        // 担当の印も確認時刻も古ければ、今までどおり担当 PC なし
        let oldAutomatic = loop(.running, discussion: 12, checkedMinutesAgo: 120)
        let gone = row([oldAutomatic, waiting], heartbeatMinutesAgo: nil).loopItems(manualLoops: [])
        #expect(gone.map { $0.row.status(now: now) } == [.unassigned, .unassigned])
    }

    @Test func headingShowsRepositoryWideStatus() {
        let loops = [loop(.running, discussion: 12), loop(.running, writer: .manual, discussion: 30)]
        let calendar = Calendar(identifier: .gregorian)
        #expect(row(loops).heading(loopCount: 2, now: now, calendar: calendar).statusText == "ループ 2 つ")

        let limited = row(loops, usageLimitedUntil: now.addingTimeInterval(3600)).heading(loopCount: 2, now: now, calendar: calendar)
        #expect(limited.statusText.hasPrefix("上限で待機中（"))
        #expect(limited.tone == .paused)

        // 担当の印も、1 行に出すループの確認時刻も古い
        var old = row(loops.map { report in
            var report = report
            report.checkedAt = now.addingTimeInterval(-3 * 3600)
            return report
        }, heartbeatMinutesAgo: nil)
        old.report?.checkedAt = now.addingTimeInterval(-3 * 3600)
        #expect(old.heading(loopCount: 2, now: now, calendar: calendar).statusText == "担当 PC なし")
    }

    @Test func countsAbnormalLoopsOneByOne() {
        // ループを並べるリポジトリでは、異常なループごとに数える
        let gaveUp = loop(.gaveUp, discussion: 12)
        let stuck = LoopStatusReport(
            state: .running,
            writer: .manual,
            epic: "epic/d30",
            discussion: 30,
            lastActivityAt: now.addingTimeInterval(-3600),
            checkedAt: now.addingTimeInterval(-60)
        )
        #expect(row([gaveUp, stuck]).abnormalLoopKeys(manualLoops: [], now: now) == ["o/r#12", "o/r#30"])
        #expect(row([gaveUp, loop(.running, writer: .manual, discussion: 30)]).abnormalLoopKeys(manualLoops: [], now: now) == ["o/r#12"])

        // ループが 1 つのリポジトリは、今までどおり行で判定する（キーはそのループ）
        #expect(row([gaveUp]).abnormalLoopKeys(manualLoops: [], now: now) == ["o/r#12"])
        let single = LoopStatusRow(repository: "o/R", report: LoopStatusReport(state: .gaveUp, checkedAt: now))
        #expect(single.abnormalLoopKeys(manualLoops: [], now: now) == ["o/r"])
    }
}
