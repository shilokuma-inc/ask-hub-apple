import Foundation
@testable import OrchestratorKit
import os
import Testing

struct OrchestratorTests {
    private struct TestError: Error {}

    /// 呼び出しを記録する GitHub
    private final class FakeGitHub: OrchestratorGitHub {
        private let state: OSAllocatedUnfairLock<(results: [Result<[ReadyDiscussion], TestError>], removed: [String])>
        private let removeFails: Bool

        init(_ results: [Result<[ReadyDiscussion], TestError>], removeFails: Bool = false) {
            state = OSAllocatedUnfairLock(initialState: (results, []))
            self.removeFails = removeFails
        }

        var removed: [String] {
            state.withLock { $0.removed }
        }

        func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion] {
            try state.withLock { state in
                state.results.isEmpty ? [] : try state.results.removeFirst().get()
            }
        }

        func removeReadyLabel(from discussion: ReadyDiscussion) async throws {
            if removeFails {
                throw TestError()
            }
            state.withLock { $0.removed.append(discussion.nodeID) }
        }
    }

    /// 起動したコマンドを記録するだけで、実際には起動しない
    private final class FakeRuntime: LoopRuntime {
        private let state = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        private let statuses: [String: LoopStatus]
        private let launchFails: Bool

        init(statuses: [String: LoopStatus] = [:], launchFails: Bool = false) {
            self.statuses = statuses
            self.launchFails = launchFails
        }

        var launched: [[String]] {
            state.withLock { $0 }
        }

        func status(of repository: RepositoryConfig) async -> LoopStatus {
            statuses[repository.fullName] ?? .idle
        }

        func launch(_ arguments: [String], for repository: RepositoryConfig) async throws {
            if launchFails {
                throw TestError()
            }
            state.withLock { $0.append(arguments) }
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

    private func makeOrchestrator(github: FakeGitHub, runtime: FakeRuntime) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            org: "shilokuma-inc",
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}", "{discussion}"])
        )
        let logs = logs
        return Orchestrator(config: config, github: github, runtime: runtime) { logs.append($0) }
    }

    @Test func launchesLoopThenRemovesLabel() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
        #expect(github.removed == ["D_12"])
        #expect(logs.recorded == ["shilokuma-inc/ask-hub-apple#12 のループを起動しました"])
    }

    @Test func keepsLabelWhenLaunchFails() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        try await makeOrchestrator(github: github, runtime: FakeRuntime(launchFails: true)).pollOnce()

        #expect(github.removed.isEmpty)
        #expect(logs.recorded.count == 1)
        #expect(logs.recorded.first?.hasPrefix("shilokuma-inc/ask-hub-apple#12 のループを起動できませんでした") == true)
    }

    @Test func logsWhenLabelCannotBeRemoved() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])], removeFails: true)
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.count == 1)
        #expect(logs.recorded.last?.hasPrefix("shilokuma-inc/ask-hub-apple#12 の ready-for-loop を外せませんでした") == true)
    }

    @Test func doesNotLaunchWhileStateFileRemains() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        let runtime = FakeRuntime(statuses: ["shilokuma-inc/ask-hub-apple": LoopStatus(stateFileExists: true, processAlive: false)])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.isEmpty)
        #expect(github.removed.isEmpty)
        #expect(logs.recorded == ["shilokuma-inc/ask-hub-apple#12 は起動しません: 制御用 worktree に .claude/ralph-loop.local.md が残っています"])
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
