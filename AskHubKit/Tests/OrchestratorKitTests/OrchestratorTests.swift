import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

private struct TestError: Error {}

private struct FakeGitHubState {
    var results: [Result<[ReadyDiscussion], TestError>]
    var removed: [String] = []
    var removedNeedsAnswer: [String] = []
    var removeFails = false
}

/// `needs-answer` の Discussion / PR を返す取得元。スレッドはテストから差し替える
private final class FakeInbox: InboxSource {
    private let state = OSAllocatedUnfairLock<(subjects: [InboxSubject], threads: [String: [QuestionThread]])>(initialState: ([], [:]))

    func set(_ subjects: [InboxSubject], threads: [String: [QuestionThread]]) {
        state.withLock { $0 = (subjects, threads) }
    }

    func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
        state.withLock { $0.subjects }
    }

    /// スレッドを登録していない Discussion / PR は取得に失敗する
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        guard let threads = state.withLock({ $0.threads[subject.nodeID] }) else {
            throw TestError()
        }
        return threads
    }
}

private struct FakeRuntimeState {
    var launched: [[String]] = []
    var status = LoopStatus.idle
    var launchFails = false
}

struct OrchestratorTests {
    /// 呼び出しを記録する GitHub。検索結果は登録した順に返し、最後のものを返し続ける
    private final class FakeGitHub: OrchestratorGitHub {
        private let state: OSAllocatedUnfairLock<FakeGitHubState>

        init(_ results: [Result<[ReadyDiscussion], TestError>]) {
            state = OSAllocatedUnfairLock(initialState: FakeGitHubState(results: results))
        }

        var removed: [String] {
            state.withLock { $0.removed }
        }

        func setRemoveFails(_ fails: Bool) {
            state.withLock { $0.removeFails = fails }
        }

        func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion] {
            try state.withLock { state in
                guard let first = state.results.first else {
                    return []
                }
                if state.results.count > 1 {
                    state.results.removeFirst()
                }
                return try first.get()
            }
        }

        var removedNeedsAnswer: [String] {
            state.withLock { $0.removedNeedsAnswer }
        }

        func removeNeedsAnswerLabel(from subject: InboxSubject) async throws {
            state.withLock { $0.removedNeedsAnswer.append(subject.nodeID) }
        }

        func removeReadyLabel(from discussion: ReadyDiscussion) async throws {
            try state.withLock { state in
                if state.removeFails {
                    throw TestError()
                }
                state.removed.append(discussion.nodeID)
            }
        }
    }

    /// 起動したコマンドを記録するだけで、実際には起動しない。ループの状態はテストから変える
    private final class FakeRuntime: LoopRuntime {
        private let state = OSAllocatedUnfairLock(initialState: FakeRuntimeState())

        var launched: [[String]] {
            state.withLock { $0.launched }
        }

        func set(_ status: LoopStatus) {
            state.withLock { $0.status = status }
        }

        func setLaunchFails(_ fails: Bool) {
            state.withLock { $0.launchFails = fails }
        }

        func status(of repository: RepositoryConfig) async -> LoopStatus {
            state.withLock { $0.status }
        }

        func launch(_ arguments: [String], for repository: RepositoryConfig) async throws {
            try state.withLock { state in
                if state.launchFails {
                    throw TestError()
                }
                state.launched.append(arguments)
                // 起動したプロセスは、テストが状態を変えるまで生きている
                state.status = LoopStatus(stateFileExists: false, processAlive: true)
            }
        }
    }

    private final class LogRecorder: Sendable {
        private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

        var recorded: [String] {
            lines.withLock { $0 }
        }

        func append(_ line: String) {
            lines.withLock { $0.append(line) }
        }
    }

    private let logs = LogRecorder()
    private static let started = LoopStatus(stateFileExists: true, processAlive: true)
    private static let exitedWithoutStarting = LoopStatus(stateFileExists: false, processAlive: false)

    private func makeOrchestrator(github: FakeGitHub, runtime: FakeRuntime, inbox: FakeInbox = FakeInbox()) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            org: "shilokuma-inc",
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}", "{discussion}"])
        )
        let logs = logs
        return Orchestrator(config: config, github: github, inbox: inbox, runtime: runtime) { logs.append($0) }
    }

    @Test func removesLabelOnlyAfterLoopStarts() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
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
        #expect(logs.recorded == ["shilokuma-inc/ask-hub-apple#12 は起動しません: 制御用 worktree に .claude/ralph-loop.local.md が残っています"])
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

    private static func ask(_ id: String, replies: [String?]) -> QuestionThread {
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
}
