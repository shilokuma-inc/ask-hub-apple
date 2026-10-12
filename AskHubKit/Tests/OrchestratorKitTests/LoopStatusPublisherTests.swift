import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct LoopStatusPublisherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trusted = TrustedAuthors(["mrs1669"])
    private let key = "o/r"

    private func loop(_ state: LoopStatusReport.State, discussion: Int? = 12, at date: Date) -> LoopStatusReport {
        LoopStatusReport(state: state, epic: discussion.map { "epic/d\($0)" }, discussion: discussion, checkedAt: date)
    }

    private func repository(at date: Date, usageLimitedUntil: Date? = nil) -> RepositoryStatusReport {
        RepositoryStatusReport(usageLimitedUntil: usageLimitedUntil, checkedAt: date)
    }

    private func record(
        _ number: Int, author: String? = "mrs1669", isOpen: Bool = true, minutesAgo: Double = 0, body: String = ""
    ) -> LoopStatusIssueRecord {
        let updatedAt = now.addingTimeInterval(-minutesAgo * 60)
        return LoopStatusIssueRecord(number: number, author: author, isOpen: isOpen, updatedAt: updatedAt, body: body)
    }

    private func comment(_ id: Int, author: String? = "mrs1669", _ report: LoopStatusReport) -> LoopStatusComment {
        LoopStatusComment(id: id, author: author, updatedAt: now, body: report.commentBody)
    }

    private func decide(
        _ publisher: LoopStatusPublisher,
        _ body: RepositoryStatusReport,
        _ loops: [LoopStatusReport],
        unknown: Bool = false,
        at date: Date,
        manualLoopOpen: Bool = false
    ) -> [LoopStatusPublisher.Action] {
        let loops = AutomaticLoops(reports: loops, includesUnknownLoop: unknown)
        return publisher.actions(repositoryKey: key, repository: body, loops: loops, now: date, manualLoopOpen: manualLoopOpen)
    }

    private func decide(
        _ publisher: LoopStatusPublisher,
        _ body: RepositoryStatusReport,
        _ loop: LoopStatusReport,
        at date: Date,
        manualLoopOpen: Bool = false
    ) -> [LoopStatusPublisher.Action] {
        decide(publisher, body, [loop], at: date, manualLoopOpen: manualLoopOpen)
    }

    /// Issue #7 に、オーケストレーターが本文とコメントを書いた状態
    private func written(_ report: LoopStatusReport, commentID: Int = 70, body: RepositoryStatusReport? = nil) -> LoopStatusPublisher {
        var publisher = LoopStatusPublisher()
        publisher.recordIssueCreated(number: 7, body: body ?? repository(at: report.checkedAt), repositoryKey: key)
        publisher.recordCommentWritten(report, id: commentID, repositoryKey: key)
        return publisher
    }

    @Test func looksUpFirstAndCreatesIssueWhenNoTrustedIssueExists() {
        var publisher = LoopStatusPublisher()
        let running = loop(.running, at: now)
        let body = repository(at: now)
        #expect(decide(publisher, body, running, at: now) == [.lookUp])

        // 信用しない author の Issue は使わない。作るのは本文だけで、コメントは作った後に決め直す
        publisher.adopt([record(5, author: "someone", body: body.issueBody)], comments: [], repositoryKey: key, trustedAuthors: trusted)
        #expect(decide(publisher, body, running, at: now) == [.createIssue(body: body.issueBody)])
        publisher.recordIssueCreated(number: 8, body: body, repositoryKey: key)
        #expect(decide(publisher, body, running, at: now)
            == [.createComment(issue: 8, report: running)])
    }

    @Test func writesRepositoryStatusToBodyAndLoopToItsComment() {
        var publisher = LoopStatusPublisher()
        // 古いオーケストレーターが本文に自動ループの状態を書いていた
        let old = loop(.running, at: now.addingTimeInterval(-60))
        publisher.adopt([record(7, body: old.issueBody)], comments: [], repositoryKey: key, trustedAuthors: trusted)

        let running = loop(.running, at: now)
        let body = repository(at: now)
        #expect(decide(publisher, body, running, at: now) == [
            .updateIssue(number: 7, body: body.issueBody),
            .createComment(issue: 7, report: running)
        ])

        // 自動ループが無いときは、本文だけを書く
        #expect(decide(publisher, body, [], at: now) == [.updateIssue(number: 7, body: body.issueBody)])
    }

    @Test func writesOnlyWhenStatusChangesOrIntervalPasses() {
        let publisher = written(loop(.running, at: now))

        // 状態が同じで間隔より前なら書かない
        let later = now.addingTimeInterval(LoopStatusReport.updateInterval - 1)
        #expect(decide(publisher, repository(at: later), loop(.running, at: later), at: later).isEmpty)

        // ループの状態が変われば、コメントだけを書き換える
        let changed = loop(.waitingForAnswer, at: later)
        #expect(decide(publisher, repository(at: later), changed, at: later) == [.updateComment(id: 70, report: changed)])

        // リポジトリ全体の状態が変われば、本文だけを書き換える
        let limited = repository(at: later, usageLimitedUntil: later.addingTimeInterval(3600))
        #expect(decide(publisher, limited, loop(.running, at: later), at: later)
            == [.updateIssue(number: 7, body: limited.issueBody)])

        // 間隔を過ぎたら、両方の確認時刻を書き直す
        let interval = now.addingTimeInterval(LoopStatusReport.updateInterval)
        let refreshed = loop(.running, at: interval)
        #expect(decide(publisher, repository(at: interval), refreshed, at: interval) == [
            .updateIssue(number: 7, body: repository(at: interval).issueBody),
            .updateComment(id: 70, report: refreshed)
        ])
    }

    @Test func adoptsNewestOpenTrustedIssueWithItsBodyAndLoopComments() {
        var publisher = LoopStatusPublisher()
        let body = repository(at: now.addingTimeInterval(-60))
        let running = loop(.running, at: now.addingTimeInterval(-60))
        let issues = [
            record(1, minutesAgo: 30, body: repository(at: now).issueBody),
            record(2, minutesAgo: 1, body: body.issueBody),
            record(3, isOpen: false, minutesAgo: 0, body: body.issueBody),
            record(4, author: "someone", minutesAgo: 0, body: body.issueBody)
        ]
        #expect(LoopStatusPublisher.issue(in: issues, trustedAuthors: trusted)?.number == 2)
        publisher.adopt(issues, comments: [comment(21, running)], repositoryKey: key, trustedAuthors: trusted)

        // 前回のオーケストレーターが書いた本文・コメントと同じなら、書き直さない
        #expect(decide(publisher, repository(at: now), loop(.running, at: now), at: now).isEmpty)
        let changed = loop(.gaveUp, at: now)
        #expect(decide(publisher, repository(at: now), changed, at: now) == [.updateComment(id: 21, report: changed)])
    }

    @Test func reopensClosedIssueAndRewritesUnreadableBody() {
        let body = repository(at: now)
        let running = loop(.running, at: now)
        var closed = LoopStatusPublisher()
        closed.adopt(
            [record(3, isOpen: false, body: body.issueBody)], comments: [comment(31, running)], repositoryKey: key, trustedAuthors: trusted
        )
        // 閉じられていれば、同じ状態でも書き直して開き直す
        #expect(decide(closed, body, running, at: now) == [.updateIssue(number: 3, body: body.issueBody)])

        var edited = LoopStatusPublisher()
        edited.adopt([record(4, body: "人が書き換えた本文")], comments: [comment(41, running)], repositoryKey: key, trustedAuthors: trusted)
        #expect(decide(edited, body, running, at: now) == [.updateIssue(number: 4, body: body.issueBody)])
    }

    @Test func keepsOldManualBodyButStillWritesLoopComment() {
        var publisher = LoopStatusPublisher()
        let manual = LoopStatusReport(state: .running, writer: .manual, epic: "epic/manual-loop", discussion: 30, checkedAt: now)
        publisher.adopt([record(7, body: manual.issueBody)], comments: [], repositoryKey: key, trustedAuthors: trusted)

        // 手で回すループ（古い形）が本文を 30 分以内に書いていれば、本文は書かない。自動ループのコメントは書く
        let within = now.addingTimeInterval(LoopStatusReport.freshness - 1)
        let running = loop(.running, at: within)
        #expect(decide(publisher, repository(at: within), running, at: within) == [.createComment(issue: 7, report: running)])

        // 手動ループの Discussion が開いている間は、確認時刻が古くなっても本文を上書きしない
        let stale = now.addingTimeInterval(LoopStatusReport.freshness + 1)
        let stillRunning = loop(.running, at: stale)
        #expect(decide(publisher, repository(at: stale), stillRunning, at: stale, manualLoopOpen: true)
            == [.createComment(issue: 7, report: stillRunning)])

        // 手動ループが終わって古くなれば、本文をリポジトリ全体の状態で書き直す
        #expect(decide(publisher, repository(at: stale), stillRunning, at: stale).first
            == .updateIssue(number: 7, body: repository(at: stale).issueBody))

        // 書き手がオーケストレーター・不明なら、手で回すループとはみなさない
        #expect(LoopStatusPublisher.isWrittenByManualLoop(manual, now: now))
        #expect(!LoopStatusPublisher.isWrittenByManualLoop(loop(.running, at: now), now: now))
        #expect(!LoopStatusPublisher.isWrittenByManualLoop(nil, now: now))
    }

    @Test func leavesDiscussionWrittenByManualLoopComment() {
        var publisher = LoopStatusPublisher()
        let manual = LoopStatusReport(state: .running, writer: .manual, epic: "epic/d12", discussion: 12, checkedAt: now)
        let mine = loop(.running, at: now.addingTimeInterval(-60))
        publisher.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [comment(71, mine), comment(72, manual)],
            repositoryKey: key,
            trustedAuthors: trusted
        )

        // 1 つの Discussion の書き手は 1 つ。手動ループが書いている Discussion には書かず、自分の重複したコメントは消す
        #expect(decide(publisher, repository(at: now), loop(.running, at: now), at: now)
            == [.deleteComment(id: 71)])
    }

    @Test func writesDiscussionAgainWhenOnlyUntrustedOrStaleManualCommentExists() {
        let mine = loop(.running, at: now)
        let stale = LoopStatusReport(
            state: .running, writer: .manual, epic: "epic/d12", discussion: 12, checkedAt: now.addingTimeInterval(-3600)
        )
        let fake = LoopStatusReport(state: .running, writer: .manual, epic: "epic/d12", discussion: 12, checkedAt: now)
        var publisher = LoopStatusPublisher()
        publisher.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [comment(71, stale), comment(72, author: "someone", fake)],
            repositoryKey: key,
            trustedAuthors: trusted
        )
        // 信用しない author の手動ループの目印では止まらない（public リポジトリでは誰でもコメントできる）。
        // 手動ループのコメントが古く、manual-loop の Discussion も無ければ、オーケストレーターが書く（手動ループのコメントは消さない）
        #expect(decide(publisher, repository(at: now), mine, at: now) == [.createComment(issue: 7, report: mine)])
        // manual-loop の Discussion が開いていれば、古くなっても書かない
        #expect(decide(publisher, repository(at: now), mine, at: now, manualLoopOpen: true).isEmpty)
    }

    @Test func leavesDiscussionOfUnknownWriterOrOldManualBody() {
        let mine = loop(.running, at: now)
        var unknown = LoopStatusPublisher()
        let future = #"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","discussion":12,"#
            + #""state":"running","writer":"robot"} -->"#
        unknown.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [LoopStatusComment(id: 71, author: "mrs1669", updatedAt: now, body: future)],
            repositoryKey: key,
            trustedAuthors: trusted
        )
        // 知らない書き手のコメントがある Discussion には書かない（消しもしない）
        #expect(decide(unknown, repository(at: now), mine, at: now).isEmpty)

        // 古い形の本文に手動ループが書いている Discussion にも、コメントを書かない
        var legacy = LoopStatusPublisher()
        let manual = LoopStatusReport(state: .running, writer: .manual, epic: "epic/d12", discussion: 12, checkedAt: now)
        legacy.adopt([record(7, body: manual.issueBody)], comments: [], repositoryKey: key, trustedAuthors: trusted)
        #expect(decide(legacy, repository(at: now), mine, at: now).isEmpty)
    }

    @Test func writesCurrentLoopBeforeDeletingPreviousOne() {
        var publisher = LoopStatusPublisher()
        publisher.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [comment(1, loop(.completed, discussion: 9, at: now))],
            repositoryKey: key,
            trustedAuthors: trusted
        )
        // 次のループのコメントを作ってから、終わったループのコメントを消す（途中で失敗しても、どちらかは残る）
        let next = loop(.waitingToStart, discussion: 20, at: now)
        #expect(decide(publisher, repository(at: now), next, at: now)
            == [.createComment(issue: 7, report: next), .deleteComment(id: 1)])
    }

    @Test func writesEachLoopToItsOwnDiscussionComment() {
        var publisher = written(loop(.completed, discussion: 12, at: now), commentID: 12)
        // 完了した #12 の最終 PR のマージ待ちの間に #30 を起動した。#12 のコメントは残し、#30 のコメントを作る
        let launched = loop(.running, discussion: 30, at: now)
        #expect(decide(publisher, repository(at: now), [loop(.completed, discussion: 12, at: now), launched], at: now)
            == [.createComment(issue: 7, report: launched)])
        publisher.recordCommentWritten(launched, id: 30, repositoryKey: key)

        // 変わったループのコメントだけを書き換える
        let later = now.addingTimeInterval(60)
        let gaveUp = loop(.gaveUp, discussion: 30, at: later)
        #expect(decide(publisher, repository(at: later), [loop(.completed, discussion: 12, at: later), gaveUp], at: later)
            == [.updateComment(id: 30, report: gaveUp)])

        // epic が退避されて #12 が一覧から消えたら（ループが終わった）、#12 のコメントだけを消す
        #expect(decide(publisher, repository(at: later), [loop(.running, discussion: 30, at: later)], at: later)
            == [.deleteComment(id: 12)])
    }

    @Test func keepsCommentsWhileLoopDiscussionIsUnknown() {
        var publisher = LoopStatusPublisher()
        publisher.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [comment(1, loop(.waitingToStart, discussion: 20, at: now))],
            repositoryKey: key,
            trustedAuthors: trusted
        )
        // どの Discussion のループか分からない（上限で待機中のまま再起動した・手で始めたループが動いている）間は、
        // 一覧に無い Discussion のコメントを、終わったものとして消さない
        #expect(decide(publisher, repository(at: now), [], unknown: true, at: now).isEmpty)
        let epic = loop(.running, discussion: 12, at: now)
        #expect(decide(publisher, repository(at: now), [epic], unknown: true, at: now) == [.createComment(issue: 7, report: epic)])
        // 分かるようになって一覧に無ければ消す
        #expect(decide(publisher, repository(at: now), [], at: now) == [.deleteComment(id: 1)])
    }

    @Test func deletesCommentsOfPreviousLoopAndDuplicates() {
        var publisher = LoopStatusPublisher()
        let previous = loop(.completed, discussion: 9, at: now)
        let current = loop(.running, at: now)
        publisher.adopt(
            [record(7, body: repository(at: now).issueBody)],
            comments: [
                comment(1, current),
                comment(2, previous),
                comment(3, current),
                // 信用しない author のコメントは、目印が同じでも読まない・消さない
                comment(4, author: "someone", current)
            ],
            repositoryKey: key,
            trustedAuthors: trusted
        )

        // 今のループのコメントは最も新しいものだけを残し、前のループのコメントと重複を消す
        #expect(decide(publisher, repository(at: now), current, at: now)
            == [.deleteComment(id: 1), .deleteComment(id: 2)])

        // ループが無くなれば（最終 PR がマージされた）、自動ループのコメントをすべて消す
        #expect(decide(publisher, repository(at: now), [], at: now)
            == [.deleteComment(id: 1), .deleteComment(id: 2), .deleteComment(id: 3)])
        // 分からないループがあっても、今のループの重複は消す
        #expect(decide(publisher, repository(at: now), [current], unknown: true, at: now) == [.deleteComment(id: 1)])
    }

    @Test func readsAgainBeforeRewritingButNotBeforeCreatingIssue() {
        #expect(LoopStatusPublisher.needsLookUp(before: [.updateComment(id: 1, report: loop(.running, at: now))]))
        #expect(LoopStatusPublisher.needsLookUp(before: [.createComment(issue: 1, report: loop(.running, at: now))]))
        #expect(LoopStatusPublisher.needsLookUp(before: [.deleteComment(id: 1)]))
        #expect(!LoopStatusPublisher.needsLookUp(before: [.createIssue(body: "")]))
        #expect(!LoopStatusPublisher.needsLookUp(before: []))
    }

    @Test func waitsUntilRetryAfterWhenRateLimited() {
        var publisher = LoopStatusPublisher()
        publisher.forget(repositoryKey: key, retryAfter: .seconds(300), now: now)
        let running = loop(.running, at: now)
        let body = repository(at: now)
        #expect(decide(publisher, body, running, at: now.addingTimeInterval(299)).isEmpty)
        #expect(decide(publisher, body, running, at: now.addingTimeInterval(300)) == [.lookUp])
        // 書けたあとに忘れたときは待たない
        publisher.forget(repositoryKey: key)
        #expect(decide(publisher, body, running, at: now) == [.lookUp])
    }

    @Test func looksUpAgainAfterForgetting() {
        var publisher = written(loop(.running, at: now))
        publisher.forget(repositoryKey: key)
        #expect(decide(publisher, repository(at: now), loop(.running, at: now), at: now) == [.lookUp])
    }
}
