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

    @Test func flagsManualLoopWithUnprocessedFinalPullRequestInstruction() {
        let completed = LoopStatusReport(state: .completed, writer: .manual, epic: "epic/x", discussion: 12, checkedAt: Self.now)
        let rows = [Self.row("o/r", report: completed)]
        let epics = [Self.epic("O/R")]

        #expect(ManualLoopItem.targets(epics: epics, rows: rows) == [ManualLoopTarget(repository: "O/R", discussion: 12, epic: "epic/x")])
        let items = ManualLoopItem.items(
            epics: epics, rows: rows, viewer: nil, needsAnswer: [], pendingFinalInstructions: ["o/r#12"], now: Self.now
        )
        #expect(items.map(\.finalInstructionsPending) == [true])
        let none = ManualLoopItem.items(epics: epics, rows: rows, viewer: nil, needsAnswer: [], now: Self.now)
        #expect(none.map(\.finalInstructionsPending) == [false])

        // 動いているループは周回の最初に指示を読むので、促さない
        let running = LoopStatusReport(state: .running, writer: .manual, epic: "epic/x", discussion: 12, checkedAt: Self.now)
        let whileRunning = ManualLoopItem.items(
            epics: epics,
            rows: [Self.row("o/r", report: running)],
            viewer: nil,
            needsAnswer: [],
            pendingFinalInstructions: ["o/r#12"],
            now: Self.now
        )
        #expect(whileRunning.map(\.finalInstructionsPending) == [false])
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

    @Test func readsEachManualLoopOfSameRepositoryFromItsComment() throws {
        // 同じリポジトリで、自動ループ（#9）と手動ループ 2 つ（#12・#20）が回っている（ループごとのコメント）
        func report(
            _ state: LoopStatusReport.State, writer: LoopStatusReport.Writer, discussion: Int, waiting: [Int]?
        ) -> LoopStatusReport {
            LoopStatusReport(
                state: state,
                writer: writer,
                discussion: discussion,
                checkedAt: Self.now.addingTimeInterval(-60),
                waitingPullRequests: waiting
            )
        }
        let automatic = report(.running, writer: .orchestrator, discussion: 9, waiting: nil)
        let first = report(.waitingForAnswer, writer: .manual, discussion: 12, waiting: [34])
        let second = report(.waitingForAnswer, writer: .manual, discussion: 20, waiting: [40])
        let body = #"<!-- ask-hub:repository-status {"checkedAt":"2027-01-15T07:59:00Z"} -->"#
        let comments = [automatic, first, second].enumerated().map { index, report in
            LoopStatusComment(id: index + 1, author: "mrs1669", updatedAt: Self.now, body: report.issueBody)
        }
        let issue = LoopStatusIssue(
            number: 1,
            url: try #require(URL(string: "https://github.com/o/r/issues/1")),
            author: "mrs1669",
            updatedAt: Self.now,
            body: body,
            comments: comments
        )
        let heartbeat = OrchestratorHeartbeat.description(at: Self.now)
        let repository = LoopStatusRepository(repository: "o/r", heartbeatDescription: heartbeat, issues: [issue])
        let rows = LoopStatusRow.rows(from: [repository], trustedAuthors: TrustedAuthors(["mrs1669"]))
        // 1 行に出す状態は自動ループでも、手動ループの行はそれぞれのループの状態を読む
        #expect(rows.first?.report == automatic)

        // #12 の回答待ちの PR #34 だけ needs-answer が外れた
        let items = ManualLoopItem.items(
            epics: [Self.epic("o/r", number: 12), Self.epic("o/r", number: 20), Self.epic("o/r", number: 9)],
            rows: rows,
            viewer: nil,
            needsAnswer: ["o/r#40"],
            now: Self.now
        )
        #expect(items.map(\.report) == [first, second, nil])
        #expect(items.map(\.answersReady) == [true, false, false])
        // 自動ループの Discussion を手動ループとして扱わない（未開始）
        #expect(items.last?.statusText == "未開始")
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
