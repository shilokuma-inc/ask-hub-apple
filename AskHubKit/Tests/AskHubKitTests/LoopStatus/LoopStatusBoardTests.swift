@testable import AskHubKit
import Foundation
import Testing

struct LoopStatusBoardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669", "partner"])

    private func report(
        _ state: LoopStatusReport.State,
        writer: LoopStatusReport.Writer = .orchestrator,
        discussion: Int?,
        checkedMinutesAgo: Double = 0
    ) -> LoopStatusReport {
        LoopStatusReport(
            state: state,
            writer: writer,
            epic: discussion.map { "epic/d\($0)" },
            discussion: discussion,
            checkedAt: now.addingTimeInterval(-checkedMinutesAgo * 60),
            runner: writer == .manual ? "partner" : nil
        )
    }

    private func comment(
        _ id: Int, author: String? = "mrs1669", updatedMinutesAgo: Double = 0, body: String
    ) -> LoopStatusComment {
        LoopStatusComment(id: id, author: author, updatedAt: now.addingTimeInterval(-updatedMinutesAgo * 60), body: body)
    }

    private func comment(
        _ id: Int, author: String? = "mrs1669", updatedMinutesAgo: Double = 0, report: LoopStatusReport
    ) -> LoopStatusComment {
        comment(id, author: author, updatedMinutesAgo: updatedMinutesAgo, body: report.issueBody)
    }

    private func read(_ issueBody: String, _ comments: [LoopStatusComment] = []) -> LoopStatusBoard {
        LoopStatusBoard(issueBody: issueBody, comments: comments, trustedAuthors: trusted)
    }

    // MARK: - 古い形の本文

    @Test func readsOldManualBodyAsOneManualLoop() {
        let manual = report(.waitingForAnswer, writer: .manual, discussion: 425)
        let board = LoopStatusBoard(issueBody: manual.issueBody, comments: [], trustedAuthors: trusted)
        #expect(board.body == .loop(manual))
        #expect(board.repository == nil)
        #expect(board.loops == [LoopStatusBoard.Loop(report: manual, source: .issueBody)])
        #expect(board.loop(discussion: 425)?.report.writer == .manual)
        #expect(board.loop(discussion: 1) == nil)
    }

    @Test func readsOldOrchestratorBodyAsOneLoopEvenWithoutDiscussion() {
        let noLoop = report(.noLoop, discussion: nil)
        let board = LoopStatusBoard(issueBody: noLoop.issueBody, comments: [], trustedAuthors: trusted)
        #expect(board.loops == [LoopStatusBoard.Loop(report: noLoop, source: .issueBody)])
        #expect(board.loops.first?.discussion == nil)

        let automatic = report(.running, discussion: 300)
        #expect(read(automatic.issueBody).loop(discussion: 300)?.report == automatic)
    }

    // MARK: - 新しい形（本文とループごとのコメント）

    @Test func readsRepositoryBodyAndLoopsFromComments() {
        let repository = RepositoryStatusReport(usageLimitedUntil: now.addingTimeInterval(3600), checkedAt: now)
        let automatic = report(.running, discussion: 425)
        let manualA = report(.running, writer: .manual, discussion: 430)
        let manualB = report(.waitingForAnswer, writer: .manual, discussion: 428)
        let board = LoopStatusBoard(
            issueBody: repository.marker + "\n## ループの状態\n",
            comments: [comment(1, report: automatic), comment(2, author: "partner", report: manualA), comment(3, report: manualB)],
            trustedAuthors: trusted
        )
        #expect(board.body == .repository(repository))
        #expect(board.repository == repository)
        // Discussion の番号の順
        #expect(board.loops == [
            LoopStatusBoard.Loop(report: automatic, source: .comment(id: 1)),
            LoopStatusBoard.Loop(report: manualB, source: .comment(id: 3)),
            LoopStatusBoard.Loop(report: manualA, source: .comment(id: 2))
        ])
        #expect(board.loop(discussion: 430)?.source == .comment(id: 2))
    }

    @Test func tellsLoopsApartByDiscussionNotAuthor() {
        // 同じアカウントが、オーケストレーターの自動ループと手動ループの両方を書く
        let automatic = report(.running, discussion: 300)
        let manual = report(.running, writer: .manual, discussion: 425)
        let board = LoopStatusBoard(
            issueBody: RepositoryStatusReport(checkedAt: now).marker,
            comments: [comment(1, report: automatic), comment(2, report: manual)],
            trustedAuthors: trusted
        )
        #expect(board.loop(discussion: 300)?.report.writer == .orchestrator)
        #expect(board.loop(discussion: 425)?.report.writer == .manual)
    }

    @Test func ignoresUntrustedAndUnreadableComments() {
        let mine = report(.running, discussion: 425)
        let board = LoopStatusBoard(
            issueBody: RepositoryStatusReport(checkedAt: now).marker,
            comments: [
                comment(1, report: mine),
                // 信用しない author のほうが新しくても使わない
                comment(2, author: "someone", report: report(.gaveUp, discussion: 425)),
                comment(3, author: "someone", report: report(.gaveUp, discussion: 999)),
                comment(4, author: nil, report: report(.gaveUp, discussion: 998)),
                // ループのコメントには Discussion の番号が要る
                comment(5, report: report(.running, discussion: nil)),
                // 目印の無いコメント・先頭に無い目印・別の目印
                comment(6, body: "人が書いたコメント"),
                comment(7, body: "メモ\n" + report(.gaveUp, discussion: 997).issueBody),
                comment(8, body: RepositoryStatusReport(checkedAt: now).marker)
            ],
            trustedAuthors: trusted
        )
        #expect(board.loops == [LoopStatusBoard.Loop(report: mine, source: .comment(id: 1))])
    }

    @Test func readsCommentsEvenWhenBodyIsUnreadable() {
        let manual = report(.running, writer: .manual, discussion: 425)
        let board = LoopStatusBoard(issueBody: "人が書き換えた本文", comments: [comment(1, report: manual)], trustedAuthors: trusted)
        #expect(board.body == .unreadable)
        #expect(board.repository == nil)
        #expect(board.loops.map(\.report) == [manual])

        #expect(LoopStatusBoard(issueBody: "", comments: [], trustedAuthors: trusted).loops.isEmpty)
    }

    // MARK: - 同じ Discussion の状態が複数あるとき

    @Test func usesNewestCheckedStateForSameDiscussion() {
        let older = report(.running, discussion: 425, checkedMinutesAgo: 20)
        let newer = report(.waitingForAnswer, discussion: 425, checkedMinutesAgo: 5)
        // コメントの更新時刻より、書き手が確かめた時刻（checkedAt）で比べる
        let board = LoopStatusBoard(
            issueBody: "",
            comments: [comment(1, updatedMinutesAgo: 30, report: newer), comment(2, updatedMinutesAgo: 0, report: older)],
            trustedAuthors: trusted
        )
        #expect(board.loops == [LoopStatusBoard.Loop(report: newer, source: .comment(id: 1))])

        // 確かめた時刻が同じなら、更新の新しいコメント、さらに同じなら id の大きいコメント
        let same = report(.running, discussion: 425)
        let tie = LoopStatusBoard(
            issueBody: "",
            comments: [
                comment(1, updatedMinutesAgo: 1, report: same),
                comment(3, updatedMinutesAgo: 2, report: same),
                comment(2, updatedMinutesAgo: 1, report: same)
            ],
            trustedAuthors: trusted
        )
        #expect(tie.loops.map(\.source) == [.comment(id: 2)])
    }

    @Test func comparesOldBodyAndCommentForSameDiscussion() {
        // ralph-kit が新しい形で書くようになると、古い形の本文が残ったままコメントが書かれる
        let oldBody = report(.running, writer: .manual, discussion: 425, checkedMinutesAgo: 40)
        let newComment = report(.running, writer: .manual, discussion: 425, checkedMinutesAgo: 1)
        let board = LoopStatusBoard(issueBody: oldBody.issueBody, comments: [comment(1, report: newComment)], trustedAuthors: trusted)
        #expect(board.body == .loop(oldBody))
        #expect(board.loops == [LoopStatusBoard.Loop(report: newComment, source: .comment(id: 1))])

        // 本文のほうが新しければ本文を使う
        let newBody = report(.completed, writer: .manual, discussion: 425, checkedMinutesAgo: 0)
        let staleComment = report(.running, writer: .manual, discussion: 425, checkedMinutesAgo: 30)
        let bodyWins = read(newBody.issueBody, [comment(1, report: staleComment)])
        #expect(bodyWins.loops == [LoopStatusBoard.Loop(report: newBody, source: .issueBody)])

        // 確かめた時刻が同じならコメントを使う
        let same = report(.running, writer: .manual, discussion: 425)
        #expect(read(same.issueBody, [comment(1, report: same)]).loops.map(\.source) == [.comment(id: 1)])
    }

    @Test func keepsOldBodyLoopOfOtherDiscussionAlongsideComments() {
        // 古い形の手動ループ（本文）と、新しい形のループ（コメント）が同時にある
        let oldManual = report(.running, writer: .manual, discussion: 430)
        let automatic = report(.running, discussion: 425)
        let noDiscussion = report(.running, discussion: nil)
        let board = LoopStatusBoard(issueBody: oldManual.issueBody, comments: [comment(1, report: automatic)], trustedAuthors: trusted)
        #expect(board.loops.map(\.discussion) == [425, 430])
        #expect(board.loop(discussion: 430)?.source == .issueBody)

        // Discussion の番号の無い古い形の本文は最後
        let withoutNumber = read(noDiscussion.issueBody, [comment(1, report: automatic)])
        #expect(withoutNumber.loops.map(\.discussion) == [425, nil])
    }
}
