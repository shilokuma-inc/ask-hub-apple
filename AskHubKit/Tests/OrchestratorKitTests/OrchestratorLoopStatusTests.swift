import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// 状態用の Issue（loop-status）の本文とループごとのコメントへの書き出し
extension OrchestratorTests {
    private static let doneGoal = "- [x] 【FEAT】A\n- [x] 【FEAT】B\n"

    /// 状態用の Issue のコメントに書かれた、ループの Discussion の番号と状態（コメントの順）
    private static func loopComments(_ github: FakeGitHub, onIssue number: Int = 101) -> [String] {
        (github.loopStatusCommentsByIssue[number] ?? []).compactMap { comment in
            LoopStatusReport.parse(comment.body).map { "#\($0.discussion ?? 0) \($0.state.rawValue)" }
        }
    }

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

    /// Issue #9 に、Discussion #12 の手動ループが 1 時間前に書いたコメントがある
    private static func staleManualLoopComment(on github: FakeGitHub, at start: Date) {
        let body = RepositoryStatusReport(checkedAt: start).issueBody
        github.setLoopStatusIssues([LoopStatusIssueRecord(number: 9, author: "mrs1669", isOpen: true, updatedAt: start, body: body)])
        let manual = LoopStatusReport(
            state: .running, writer: .manual, epic: "epic/mvp", discussion: 12, checkedAt: start.addingTimeInterval(-3600)
        )
        github.setLoopStatusComments([LoopStatusComment(id: 90, author: "mrs1669", updatedAt: start, body: manual.commentBody)], onIssue: 9)
    }

    @Test func writesDiscussionSwitchedFromManualLoopWhileAnotherManualLoopIsOpen() async throws {
        let github = FakeGitHub([.success([])])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        Self.staleManualLoopComment(on: github, at: start)
        // #12 を手動ループから自動ループに切り替えた。同じリポジトリでは #30 を手で回している
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 30, author: "mrs1669")])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        try await makeOrchestrator(github: github, runtime: runtime) { start }.pollOnce()

        // ほかの Discussion の手動ループがあっても、#12 の古い手動ループのコメントでは止まらず、自動ループのコメントを書く
        #expect(github.createdLoopStatusComments == ["shilokuma-inc/ask-hub-apple#9"])
        #expect(github.loopCommentReport(onIssue: 9)?.writer == .orchestrator)
        #expect(github.loopCommentReport(onIssue: 9)?.discussion == 12)
        #expect(github.deletedLoopStatusComments.isEmpty)
    }

    @Test func keepsManualLoopDiscussionWithPreviousNumbersWhenSearchFails() async throws {
        let github = FakeGitHub([.success([])])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        Self.staleManualLoopComment(on: github, at: start)
        // 自動ループの #12 を手動ループに切り替えた（制御用 worktree には #12 の epic が残っている）
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 12, author: "mrs1669")])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] B\n", state: nil, discussion: 12, loopPrepared: true))
        let clock = OSAllocatedUnfairLock(initialState: start)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime) { clock.withLock { $0 } }

        // #12 が manual-loop の Discussion のあいだは、手動ループのコメントが古くなっても書かない
        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusComments.isEmpty)

        // manual-loop の Discussion を検索できなかったポーリングでは、前回取得できた番号を使う
        github.setManualLoopsFail(true)
        clock.withLock { $0 = start.addingTimeInterval(LoopStatusReport.updateInterval) }
        try await orchestrator.pollOnce()
        #expect(logs.recorded.contains { $0.hasPrefix("manual-loop の Discussion を検索できませんでした") })
        #expect(github.updatedLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#9"])
        #expect(github.createdLoopStatusComments.isEmpty)

        // #12 の manual-loop の Discussion が閉じたら、自動ループのコメントを書く（手動ループのコメントは消さない）
        github.setManualLoopsFail(false)
        github.setManualLoops([])
        try await orchestrator.pollOnce()
        #expect(github.createdLoopStatusComments == ["shilokuma-inc/ask-hub-apple#9"])
        #expect(github.loopCommentReport(onIssue: 9)?.writer == .orchestrator)
        #expect(github.deletedLoopStatusComments.isEmpty)
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

    @Test func writesLoopBeingStartedUnderLaunchedDiscussion() async throws {
        let github = FakeGitHub([
            .success([.fixture(number: 20), .fixture(number: 10, isManualLoop: true), .fixture(number: 15, author: "someone")])
        ])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // ready-for-loop の #20 を起動した。準備が終わる前（ゴール元の記録も promise も無い）も、起動した #20 のループとして書く。
        // 手動ループ・信用しない author の Discussion（#10・#15）は、この PC の開始待ちとして数えない
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        let started = try #require(github.loopCommentReport())
        #expect(started.state == .running)
        #expect(started.discussion == 20)
        #expect(github.loopStatusCommentsByIssue[101]?.count == 1)
    }

    @Test func deletesCommentOfMergedEpicAndKeepsWaitingDiscussions() async throws {
        let github = FakeGitHub([.success([.fixture(number: 30), .fixture(number: 20), .fixture(repository: "other/repo", number: 5)])])
        let runtime = FakeRuntime()
        // 前の epic（#12）は完了し、最終 PR のマージを待っている。次の Discussion（#20・#30）は起動を待っている
        // （state ファイルを確かめられない間は起動しない）
        runtime.set(LoopStatus(stateFileExists: nil, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: Self.doneGoal, state: nil, discussion: 12, loopPrepared: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.isEmpty)
        #expect(Self.loopComments(github) == ["#12 completed", "#20 waiting-to-start", "#30 waiting-to-start"])

        // 最終 PR がマージされた。#12 のループは終わったのでコメントを消し、待っている #20・#30 のコメントは残す
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 40, isOpen: false, isMerged: true))
        let clock = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(LoopStatusReport.updateInterval)
        let next = try makeOrchestrator(github: github, runtime: runtime) { clock }
        try await next.pollOnce()
        #expect(runtime.launched.isEmpty)
        #expect(Self.loopComments(github) == ["#20 waiting-to-start", "#30 waiting-to-start"])
        #expect(github.deletedLoopStatusComments.count == 1)
        #expect(github.createdLoopStatusComments.count == 3)
    }

    @Test func writesCompletedEpicAndLaunchedDiscussionToSeparateComments() async throws {
        let github = FakeGitHub([.success([.fixture(number: 30)])])
        let runtime = FakeRuntime()
        // 完了した #12 の最終 PR がマージを待っている間に、次の #30 を起動する
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: Self.doneGoal, state: nil, discussion: 12, loopPrepared: true))
        github.addExistingPullRequest(head: "epic/mvp", ExistingPullRequest(number: 40, isOpen: true, isMerged: false))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        // 動いているプロセスは #30 のもの。#12 は完了のまま、#30 は実行中として、それぞれのコメントに書く
        #expect(Self.loopComments(github) == ["#12 completed", "#30 running"])
        #expect(github.deletedLoopStatusComments.isEmpty)
    }

    @Test func keepsWaitingLoopCommentsWhileReadyDiscussionsAreUnknown() async throws {
        let github = FakeGitHub([.success([.fixture(number: 20)])])
        let runtime = FakeRuntime()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let waiting = LoopStatusReport(state: .waitingToStart, discussion: 20, checkedAt: start.addingTimeInterval(-60))
        let body = RepositoryStatusReport(checkedAt: start).issueBody
        github.setLoopStatusIssues([LoopStatusIssueRecord(number: 9, author: "mrs1669", isOpen: true, updatedAt: start, body: body)])
        let comment = LoopStatusComment(id: 90, author: "mrs1669", updatedAt: start, body: waiting.commentBody)
        github.setLoopStatusComments([comment], onIssue: 9)
        // 上限で待機中に再起動した。ready-for-loop の一覧を取り直さないので、#20 のループが終わったのか分からない
        runtime.setUsageLimitReset(start.addingTimeInterval(3600))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime) { start }
        try await orchestrator.pollOnce()
        #expect(github.deletedLoopStatusComments.isEmpty)
        #expect(Self.loopComments(github, onIssue: 9) == ["#20 waiting-to-start"])
        #expect(github.repositoryStatus(onIssue: 9)?.usageLimitedUntil == start.addingTimeInterval(3600))
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
