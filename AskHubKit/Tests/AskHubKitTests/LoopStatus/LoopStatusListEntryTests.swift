@testable import AskHubKit
import Foundation
import Testing

/// ステータスタブのリポジトリの節を、1 要素 = 1 行の並びにする
struct LoopStatusListEntryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])

    private func loop(
        _ state: LoopStatusReport.State, writer: LoopStatusReport.Writer = .orchestrator, discussion: Int
    ) -> LoopStatusReport {
        let checkedAt = now.addingTimeInterval(-60)
        return LoopStatusReport(state: state, writer: writer, epic: "epic/d\(discussion)", discussion: discussion, checkedAt: checkedAt)
    }

    /// 本文（新しい形）と、ループごとのコメントを持つリポジトリの行
    private func row(_ repository: String, loops: [LoopStatusReport]) -> LoopStatusRow {
        let body = RepositoryStatusReport(checkedAt: now.addingTimeInterval(-60)).marker
        let comments = loops.enumerated().map { index, report in
            LoopStatusComment(id: index + 1, author: "mrs1669", updatedAt: now, body: report.issueBody)
        }
        let issue = LoopStatusIssue(
            number: 1, url: URL(string: "https://github.com/\(repository)/issues/1")!, author: "mrs1669", updatedAt: now, body: body, comments: comments
        )
        let heartbeat = OrchestratorHeartbeat.description(at: now.addingTimeInterval(-60))
        let source = LoopStatusRepository(repository: repository, heartbeatDescription: heartbeat, issues: [issue])
        return LoopStatusRow.rows(from: [source], trustedAuthors: trusted)[0]
    }

    @Test func listsRepositoriesAsOneRowAndMultipleLoopsUnderHeading() {
        let rows = [
            row("o/Alpha", loops: [loop(.running, discussion: 3)]),
            row("o/beta", loops: [loop(.running, discussion: 12), loop(.waitingForAnswer, writer: .manual, discussion: 30)]),
            row("o/gamma", loops: [])
        ]
        let entries = LoopStatusListEntry.entries(of: rows, manualLoops: [])
        #expect(entries.map(\.id) == [
            "repository:o/alpha", "heading:o/beta", "loop:o/beta#12", "loop:o/beta#30", "repository:o/gamma"
        ])
        #expect(entries[1].kind == .heading(rows[1], loopCount: 2))
    }

    @Test func eachRepositoryChangesRowsWithoutReusingIDsAcrossKinds() {
        // ループ 1 つ → 2 つ → 0 と変わっても、行の id は種類ごとに分かれ、1 要素は常に 1 行
        let one = LoopStatusListEntry.entries(of: [row("o/r", loops: [loop(.running, discussion: 12)])], manualLoops: [])
        let two = LoopStatusListEntry.entries(
            of: [row("o/r", loops: [loop(.running, discussion: 12), loop(.running, discussion: 13)])], manualLoops: []
        )
        let none = LoopStatusListEntry.entries(of: [row("o/r", loops: [])], manualLoops: [])
        #expect(one.map(\.id) == ["repository:o/r"])
        #expect(two.map(\.id) == ["heading:o/r", "loop:o/r#12", "loop:o/r#13"])
        #expect(none.map(\.id) == ["repository:o/r"])
        for entries in [one, two, none] {
            #expect(Set(entries.map(\.id)).count == entries.count)
        }
    }

    @Test func idsDoNotCollideBetweenRepositoryAndLoopWithoutDiscussion() {
        // 古い形の本文のループ（Discussion の番号なし）の id はリポジトリ名と同じになるが、種類の接頭辞で分かれる
        let legacy = LoopStatusReport(state: .running, writer: .manual, checkedAt: now.addingTimeInterval(-60))
        let comment = LoopStatusComment(id: 1, author: "mrs1669", updatedAt: now, body: loop(.running, discussion: 12).issueBody)
        let issue = LoopStatusIssue(
            number: 1, url: URL(string: "https://github.com/o/r/issues/1")!, author: "mrs1669", updatedAt: now, body: legacy.issueBody, comments: [comment]
        )
        let rows = LoopStatusRow.rows(from: [
            LoopStatusRepository(repository: "o/r", heartbeatDescription: OrchestratorHeartbeat.description(at: now), issues: [issue])
        ], trustedAuthors: trusted)
        let entries = LoopStatusListEntry.entries(of: rows, manualLoops: [])
        #expect(entries.map(\.id) == ["heading:o/r", "loop:o/r#12", "loop:o/r"])
    }

    @Test func keepsFirstOfDuplicatedRows() {
        let first = row("o/r", loops: [loop(.running, discussion: 12)])
        let entries = LoopStatusListEntry.entries(of: [first, row("O/R", loops: [loop(.gaveUp, discussion: 12)])], manualLoops: [])
        #expect(entries == [LoopStatusListEntry(kind: .repository(first))])
    }
}
