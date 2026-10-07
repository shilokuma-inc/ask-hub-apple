import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct OrchestratorTests {
    let logs = LogRecorder()
    static let started = LoopStatus(stateFileExists: true, processAlive: true)
    static let exitedWithoutStarting = LoopStatus(stateFileExists: false, processAlive: false)

    func makeOrchestrator(
        github: FakeGitHub,
        runtime: FakeRuntime,
        inbox: FakeInbox = FakeInbox(),
        repositories: [RepositoryConfig] = [
            RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
        ],
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: repositories,
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}", "{discussion}"])
        )
        let logs = logs
        return Orchestrator(config: config, github: github, inbox: inbox, runtime: runtime, log: { logs.append($0) }, now: now)
    }

    @Test func launchesLoopOfRepositoryInAnotherOrganization() async throws {
        let github = FakeGitHub([.success([.fixture(repository: "BeaconFun4/demomoni-remake-ios", number: 3)])])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, repositories: [
            RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
            RepositoryConfig(owner: "BeaconFun4", name: "demomoni-remake-ios", checkoutPath: "/src/demomoni-remake-ios")
        ])

        try await orchestrator.pollOnce()

        // 担当リポジトリの owner をまとめて 1 回で検索する
        #expect(github.searchedOrgs == [["shilokuma-inc", "BeaconFun4"]])
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "BeaconFun4/demomoni-remake-ios", "3"]])
    }

    @Test func removesLabelOnlyAfterLoopStarts() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        // 起動スクリプトは準備元の Discussion の番号を残す
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil, discussion: 12))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
        #expect(github.removed.isEmpty)

        // state ファイルが現れるまではラベルを外さず、起動もし直さない
        try await orchestrator.pollOnce()
        #expect(github.removed.isEmpty)
        #expect(runtime.launched.count == 1)

        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(github.removed == ["D_12"])
        #expect(runtime.launched.count == 1)
    }

    @Test func doesNotRelaunchWhileLabelCannotBeRemoved() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        github.setRemoveFails(true)
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil, discussion: 12))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        #expect(logs.recorded.last?.hasPrefix("shilokuma-inc/ask-hub-apple#12 の ready-for-loop を外せませんでした") == true)

        // ループが終わって state ファイルが消えても、ラベルが残っている Discussion を起動し直さない
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)

        github.setRemoveFails(false)
        try await orchestrator.pollOnce()
        #expect(github.removed == ["D_12"])
        #expect(runtime.launched.count == 1)
    }

    @Test func retriesWhenProcessExitsWithoutStartingAndGivesUp() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        for _ in 0..<LaunchTracker.maxAttempts {
            try await orchestrator.pollOnce()
            runtime.set(Self.exitedWithoutStarting)
        }
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.launched.count == LaunchTracker.maxAttempts)
        #expect(github.removed.isEmpty)
        #expect(await orchestrator.trackedEntries["D_12"]?.phase == .gaveUp)
        #expect(logs.recorded.contains { $0.contains("起動をやめます") })
    }

    @Test func keepsLabelAndRetriesWhenLaunchFails() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.setLaunchFails(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.removed.isEmpty)
        #expect(logs.recorded.first?.hasPrefix("shilokuma-inc/ask-hub-apple#12 のループを起動できませんでした（1/3 回目）") == true)

        runtime.setLaunchFails(false)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        let entry = await orchestrator.trackedEntries["D_12"]
        #expect(entry == LaunchTracker.Entry(repositoryKey: "shilokuma-inc/ask-hub-apple", attempts: 2, phase: .starting))
    }

    @Test func doesNotLaunchWhileStateFileRemains() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.isEmpty)
        #expect(github.removed.isEmpty)
        // 状態用の Issue を作ったログ（Orchestrator+LoopStatus）は除いて比べる
        #expect(logs.recorded.filter { !$0.contains("ループの状態") } == [
            "shilokuma-inc/ask-hub-apple#12 は起動しません: 制御用 worktree に .claude/ralph-loop.local.md が残っています"
        ])
    }

    // MARK: - ask への回答

    private static func pullRequest(repository: String = "shilokuma-inc/ask-hub-apple", number: Int = 34) -> InboxSubject {
        InboxSubject(
            kind: .pullRequest,
            nodeID: "PR_\(number)",
            repository: repository,
            number: number,
            title: "PR",
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!
        )
    }

    static func ask(_ id: String, replies: [String?]) -> QuestionThread {
        QuestionThread(
            comment: InboxComment(
                nodeID: id,
                databaseID: 1,
                author: "mrs1669",
                body: #"<!-- ask-hub:question id="pr34-1" options="A|B" -->"#,
                url: URL(string: "https://github.com")!,
                createdAt: Date()
            ),
            replyAuthors: replies
        )
    }

    @Test func resumesStoppedLoopWhenAskIsAnsweredAndRemovesNeedsAnswer() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        let inbox = FakeInbox()
        let subject = Self.pullRequest()
        inbox.set([subject], threads: ["PR_34": [Self.ask("C_1", replies: ["mrs1669"])]])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, inbox: inbox)

        try await orchestrator.pollOnce()
        // 再開では {discussion} が空になる
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        #expect(github.removedNeedsAnswer == ["PR_34"])

        // 再開を確かめたら、同じ回答では再開しない
        runtime.set(Self.started)
        try await orchestrator.pollOnce()
        runtime.set(.idle)
        try await orchestrator.pollOnce()
        #expect(runtime.launched.count == 1)
        #expect(await orchestrator.pendingResumes.isEmpty)
    }

    @Test func addsReadyForLoopWhenAllDiscussionQuestionsAreAnswered() async throws {
        let github = FakeGitHub([.success([])])
        let inbox = FakeInbox()
        let discussion = InboxSubject(
            kind: .discussion,
            nodeID: "D_115",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 115,
            title: "依頼",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/115")!
        )
        inbox.set(
            [discussion, Self.pullRequest()],
            threads: [
                "D_115": [Self.ask("C_1", replies: ["mrs1669"]), Self.ask("C_2", replies: ["mrs1669"])],
                "PR_34": [Self.ask("C_3", replies: ["mrs1669"])]
            ]
        )
        try await makeOrchestrator(github: github, runtime: FakeRuntime(), inbox: inbox).pollOnce()

        // Discussion には ready-for-loop を付けてから needs-answer を外す。PR の ask には付けない
        #expect(github.addedReady == ["D_115"])
        #expect(Set(github.removedNeedsAnswer) == ["D_115", "PR_34"])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#115 の質問がすべて回答されたので、ready-for-loop を付けました（ループを始めます）"))
    }

    @Test func keepsNeedsAnswerWhenReadyForLoopCannotBeAdded() async throws {
        let github = FakeGitHub([.success([])])
        github.setAddReadyFails(true)
        let inbox = FakeInbox()
        let discussion = InboxSubject(
            kind: .discussion,
            nodeID: "D_115",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 115,
            title: "依頼",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/115")!
        )
        inbox.set([discussion], threads: ["D_115": [Self.ask("C_1", replies: ["mrs1669"])]])
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime(), inbox: inbox)
        try await orchestrator.pollOnce()

        // 付けられなければ needs-answer を残し、次のポーリングで回答待ちとして見つけ直す
        #expect(github.addedReady.isEmpty)
        #expect(github.removedNeedsAnswer.isEmpty)

        github.setAddReadyFails(false)
        try await orchestrator.pollOnce()
        #expect(github.addedReady == ["D_115"])
        #expect(github.removedNeedsAnswer == ["D_115"])
    }

    @Test func doesNotResumeRunningLoopOrOtherPCRepository() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.set(Self.started)
        let inbox = FakeInbox()
        inbox.set(
            [Self.pullRequest(), Self.pullRequest(repository: "shilokuma-inc/notti-ios", number: 7)],
            threads: [
                "PR_34": [Self.ask("C_1", replies: ["mrs1669"]), Self.ask("C_2", replies: [])],
                "PR_7": [Self.ask("C_3", replies: ["mrs1669"])]
            ]
        )
        try await makeOrchestrator(github: github, runtime: runtime, inbox: inbox).pollOnce()

        // 動いているループは自分で回答を拾う。別の PC の担当には触らない。未回答が残る PR のラベルは外さない
        #expect(runtime.launched.isEmpty)
        #expect(github.removedNeedsAnswer.isEmpty)
    }

    @Test func skipsOnlySubjectWhoseQuestionsCannotBeFetched() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        let inbox = FakeInbox()
        // PR_1 はスレッドを登録していないので取得に失敗する
        inbox.set([Self.pullRequest(number: 1), Self.pullRequest()], threads: ["PR_34": [Self.ask("C_1", replies: ["mrs1669"])]])
        try await makeOrchestrator(github: github, runtime: runtime, inbox: inbox).pollOnce()

        #expect(runtime.launched.count == 1)
        #expect(github.removedNeedsAnswer == ["PR_34"])
        #expect(logs.recorded.first?.hasPrefix("shilokuma-inc/ask-hub-apple#1 の質問を取得できませんでした") == true)
    }

    @Test func resumeAndReadyForLoopDoNotLaunchTwiceInOnePoll() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        let inbox = FakeInbox()
        inbox.set([Self.pullRequest()], threads: ["PR_34": [Self.ask("C_1", replies: ["mrs1669"])]])
        try await makeOrchestrator(github: github, runtime: runtime, inbox: inbox).pollOnce()

        #expect(runtime.launched.count == 1)
    }

    @Test func runContinuesAfterFailedPollAndStopsWhenSleepThrows() async throws {
        let github = FakeGitHub([.failure(TestError()), .success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        let sleeps = OSAllocatedUnfairLock(initialState: 0)
        try await makeOrchestrator(github: github, runtime: runtime).run { _ in
            let count = sleeps.withLock { count in
                count += 1
                return count
            }
            if count == 2 {
                throw CancellationError()
            }
        }

        #expect(sleeps.withLock { $0 } == 2)
        #expect(runtime.launched.count == 1)
        #expect(logs.recorded.first?.hasPrefix("ポーリングに失敗しました") == true)
    }

    @Test func removesLabelOfDiscussionWhoseLoopStartedBeforeRestart() async throws {
        // 再起動の前に #12 から準備を終えてループを始めていた（追跡は消えている）
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil, discussion: 12, loopPrepared: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(github.removed == ["D_12"])
        #expect(runtime.launched.isEmpty)
    }

    @Test func relaunchesDiscussionWhosePreparationWasInterrupted() async throws {
        // 準備が途中（完了語が無い）なら、ラベルを外さず起動し直す（起動スクリプトが準備をやり直す）
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil, discussion: 12, loopPrepared: false))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(github.removed.isEmpty)
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
    }

    @Test func stopsDiscussionWithoutTasksAndTellsItOnce() async throws {
        // 準備の結果 goal にタスクが無かった（起動スクリプトが目印を残した）
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "# goal\n", state: nil, discussion: 12, noTasksDiscussion: 12))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        let decisions = try await orchestrator.pollOnce()

        // やり直さず、Discussion に知らせて ready-for-loop を外し、目印を消す
        #expect(decisions == [.skip(.fixture(number: 12), .alreadyLaunched)])
        #expect(runtime.launched.isEmpty)
        #expect(github.discussionComments == ["D_12: \(Orchestrator.noTasksComment)"])
        #expect(github.removed == ["D_12"])
        #expect(runtime.clearedNoTasksMarkers == 1)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#12 は準備の結果やることが残っていなかったので、知らせて ready-for-loop を外しました"))
    }
}
