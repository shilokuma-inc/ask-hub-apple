import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
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
        _ loop: LoopStatusReport,
        at date: Date,
        manualLoopOpen: Bool = false
    ) -> [LoopStatusPublisher.Action] {
        publisher.actions(repositoryKey: key, repository: body, loop: loop, now: date, manualLoopOpen: manualLoopOpen)
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
            == [.createComment(issue: 8, body: running.commentBody)])
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
            .createComment(issue: 7, body: running.commentBody)
        ])

        // ゴール元の Discussion が無い（ループが無いなど）ときは、本文だけを書く
        #expect(decide(publisher, body, loop(.noLoop, discussion: nil, at: now), at: now)
            == [.updateIssue(number: 7, body: body.issueBody)])
    }

    @Test func writesOnlyWhenStatusChangesOrIntervalPasses() {
        let publisher = written(loop(.running, at: now))

        // 状態が同じで間隔より前なら書かない
        let later = now.addingTimeInterval(LoopStatusReport.updateInterval - 1)
        #expect(decide(publisher, repository(at: later), loop(.running, at: later), at: later).isEmpty)

        // ループの状態が変われば、コメントだけを書き換える
        let changed = loop(.waitingForAnswer, at: later)
        #expect(decide(publisher, repository(at: later), changed, at: later)
            == [.updateComment(id: 70, body: changed.commentBody)])

        // リポジトリ全体の状態が変われば、本文だけを書き換える
        let limited = repository(at: later, usageLimitedUntil: later.addingTimeInterval(3600))
        #expect(decide(publisher, limited, loop(.running, at: later), at: later)
            == [.updateIssue(number: 7, body: limited.issueBody)])

        // 間隔を過ぎたら、両方の確認時刻を書き直す
        let interval = now.addingTimeInterval(LoopStatusReport.updateInterval)
        let refreshed = loop(.running, at: interval)
        #expect(decide(publisher, repository(at: interval), refreshed, at: interval) == [
            .updateIssue(number: 7, body: repository(at: interval).issueBody),
            .updateComment(id: 70, body: refreshed.commentBody)
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
        #expect(decide(publisher, repository(at: now), changed, at: now)
            == [.updateComment(id: 21, body: changed.commentBody)])
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
        #expect(decide(publisher, repository(at: within), running, at: within)
            == [.createComment(issue: 7, body: running.commentBody)])

        // 手動ループの Discussion が開いている間は、確認時刻が古くなっても本文を上書きしない
        let stale = now.addingTimeInterval(LoopStatusReport.freshness + 1)
        let stillRunning = loop(.running, at: stale)
        #expect(decide(publisher, repository(at: stale), stillRunning, at: stale, manualLoopOpen: true)
            == [.createComment(issue: 7, body: stillRunning.commentBody)])

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
        #expect(decide(publisher, repository(at: now), mine, at: now) == [.createComment(issue: 7, body: mine.commentBody)])
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
        // 次のループのコメントを作ってから、前のループのコメントを消す（途中で失敗しても、どちらかは残る）
        let next = loop(.waitingToStart, discussion: 20, at: now)
        #expect(decide(publisher, repository(at: now), next, at: now)
            == [.createComment(issue: 7, body: next.commentBody), .deleteComment(id: 1)])
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
        #expect(decide(publisher, repository(at: now), loop(.noLoop, discussion: nil, at: now), at: now)
            == [.deleteComment(id: 1), .deleteComment(id: 2), .deleteComment(id: 3)])
    }

    @Test func readsAgainBeforeRewritingButNotBeforeCreatingIssue() {
        #expect(LoopStatusPublisher.needsLookUp(before: [.updateComment(id: 1, body: "")]))
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

// MARK: - 状態用の Issue の書き出し

extension OrchestratorTests {
    private static let doneGoal = "- [x] 【FEAT】A\n- [x] 【FEAT】B\n"

    @Test func createsStatusIssueWithLoopCommentAndRewritesOnlyOnChangeOrInterval() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] A\n- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        let activity = Date(timeIntervalSince1970: 1_800_000_000 - 120)
        runtime.setLastActivity(activity)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime) { clock.withLock { $0 } }

        try await orchestrator.pollOnce()
        // 本文はリポジトリ全体の状態、自動ループの状態は Discussion #12 のコメント
        #expect(github.createdLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
        #expect(github.repositoryStatus() == RepositoryStatusReport(checkedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(github.createdLoopStatusComments == ["shilokuma-inc/ask-hub-apple#101"])
        #expect(github.loopCommentReport() == LoopStatusReport(
            state: .running,
            epic: "epic/mvp",
            discussion: 12,
            progress: .init(completed: 1, total: 2, deferred: 0),
            lastActivityAt: activity,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        // 本文にもコメントにもローカルパスを書かない
        #expect(github.loopStatusIssuesByNumber[101]?.body.contains("/src/ask-hub-apple") == false)
        #expect(github.loopStatusCommentsByIssue[101]?.contains { $0.body.contains("/src/ask-hub-apple") } == false)

        // 変わらなければ、間隔より前は書かず、一覧も取り直さない
        #expect(github.loopStatusIssueListings == 1)
        clock.withLock { $0 = $0.addingTimeInterval(60) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(github.updatedLoopStatusComments.isEmpty)
        #expect(github.loopStatusIssueListings == 1)

        // ループの状態が変われば、読み直してからコメントだけを書き換える
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(github.loopStatusIssueListings == 2)
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(github.updatedLoopStatusComments.count == 1)
        #expect(github.loopCommentReport()?.state == .waitingToStart)

        // 間隔を過ぎたら、本文とコメントの確認時刻を書き直す
        clock.withLock { $0 = $0.addingTimeInterval(LoopStatusReport.updateInterval) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
        #expect(github.updatedLoopStatusComments.count == 2)
        #expect(github.createdLoopStatusIssues.count == 1)
        #expect(github.createdLoopStatusComments.count == 1)
        #expect(github.loopStatusCommentsByIssue[101]?.count == 1)
    }

    @Test func keepsOldManualBodyAndStillWritesAutomaticLoopComment() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime) { clock.withLock { $0 } }
        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])

        // 手で回すループ（ralph-kit が新しい形で書くまでは古い形）が同じ Issue の本文に書いた
        let manual = LoopStatusReport(
            state: .running, writer: .manual, epic: "epic/manual-loop", discussion: 30, checkedAt: start.addingTimeInterval(300)
        )
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 101, author: "mrs1669", isOpen: true, updatedAt: start, body: manual.issueBody)
        ])

        // 間隔を過ぎて書き直す前に読み直し、本文は上書きしない。自動ループのコメントは書き続ける
        runtime.set(LoopStatus(stateFileExists: true, processAlive: true))
        clock.withLock { $0 = start.addingTimeInterval(LoopStatusReport.updateInterval) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) }?.writer == .manual)
        #expect(github.loopCommentReport()?.state == .running)

        // 手で回すループが止まり、確認時刻から 30 分を過ぎたら、本文をリポジトリ全体の状態で書き直す
        clock.withLock { $0 = start.addingTimeInterval(300 + LoopStatusReport.freshness + 1) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
        #expect(github.repositoryStatus() != nil)
    }

    @Test func doesNotCreateDuplicateCommentWhenCommentsCannotBeRead() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        let mine = LoopStatusReport(state: .running, epic: "epic/mvp", discussion: 12, checkedAt: .distantPast)
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 9, author: "mrs1669", isOpen: true, updatedAt: .distantPast, body: "")
        ])
        github.setLoopStatusComments(
            [LoopStatusComment(id: 90, author: "mrs1669", updatedAt: .distantPast, body: mine.commentBody)], onIssue: 9
        )
        github.setLoopStatusCommentsFail(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // コメントを読めなければ、何も書かずに次のポーリングで書き直す（既にあるコメントと重複させない）
        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusComments.isEmpty)
        #expect(github.updatedLoopStatusIssues.isEmpty)
        #expect(logs.recorded.contains { $0.hasPrefix("shilokuma-inc/ask-hub-apple にループの状態を書けませんでした") })

        github.setLoopStatusCommentsFail(false)
        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusComments.isEmpty)
        #expect(github.updatedLoopStatusComments == ["shilokuma-inc/ask-hub-apple 90"])
    }

    @Test func reusesExistingTrustedIssueAndRetriesAfterFailure() async throws {
        let github = FakeGitHub([.success([])])
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 5, author: "someone", isOpen: true, updatedAt: .distantFuture, body: "spam"),
            LoopStatusIssueRecord(number: 9, author: "mrs1669", isOpen: false, updatedAt: .distantPast, body: "")
        ])
        github.setLoopStatusFails(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())

        // 書けなくてもほかの判定は続け、次のポーリングで書き直す
        try await orchestrator.pollOnce()
        #expect(logs.recorded.contains { $0.hasPrefix("shilokuma-inc/ask-hub-apple にループの状態を書けませんでした") })

        github.setLoopStatusFails(false)
        try await orchestrator.pollOnce()
        // 信用する author の閉じた Issue を開き直して使う。ループが無いので、コメントは書かない
        #expect(github.createdLoopStatusIssues.isEmpty)
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#9"])
        #expect(github.loopStatusIssuesByNumber[9]?.isOpen == true)
        #expect(github.repositoryStatus(onIssue: 9) != nil)
        #expect(github.createdLoopStatusComments.isEmpty)
    }

    @Test func writesLoopBeingStartedAndGivenUpUnderItsDiscussion() async throws {
        let github = FakeGitHub([
            .success([.fixture(number: 20), .fixture(number: 25, isManualLoop: true), .fixture(number: 15, author: "someone")])
        ])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // ready-for-loop の #20 を起動した。準備が終わる前（ゴール元の記録も promise も無い）も、#20 のループとして書く。
        // 手動ループ・信用しない author の Discussion（#25・#15）は、この PC の開始待ちとして数えない
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        let started = try #require(github.loopCommentReport())
        #expect(started.state == .running)
        #expect(started.discussion == 20)
        #expect(github.loopStatusCommentsByIssue[101]?.count == 1)
    }

    @Test func movesCommentToNextLoopAfterEpicIsMerged() async throws {
        let github = FakeGitHub([.success([.fixture(number: 30), .fixture(number: 20), .fixture(repository: "other/repo", number: 5)])])
        let runtime = FakeRuntime()
        // 前の epic（#12）は完了し、最終 PR のマージを待っている
        runtime.set(LoopStatus(stateFileExists: nil, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: Self.doneGoal, state: nil, discussion: 12, loopPrepared: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(github.loopCommentReport()?.state == .completed)
        #expect(github.loopCommentReport()?.discussion == 12)

        // 最終 PR がマージされた。次の Discussion は起動を待っている（state ファイルを確かめられない間は起動しない）
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 40, isOpen: false, isMerged: true))
        let clock = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(LoopStatusReport.updateInterval)
        let next = try makeOrchestrator(github: github, runtime: runtime) { clock }
        try await next.pollOnce()
        #expect(runtime.launched.isEmpty)
        // 前のループのコメントを消し、次のループ（#20）のコメントを作る
        let comments = github.loopStatusCommentsByIssue[101] ?? []
        #expect(comments.count == 1)
        let waiting = try #require(comments.first.flatMap { LoopStatusReport.parse($0.body) })
        #expect(waiting.state == .waitingToStart)
        #expect(waiting.discussion == 20)
        #expect(github.deletedLoopStatusComments.count == 1)
    }

    @Test func reportsWaitingForAnswerWhileOnlyAskedTasksRemain() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(
            branch: "epic/mvp", goal: "- [x] A\n- [ ] B ※回答待ち（PR #3 / ask id 4）\n", state: nil, discussion: 12, loopPrepared: true
        ))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(github.loopCommentReport()?.state == .waitingForAnswer)
    }
}
