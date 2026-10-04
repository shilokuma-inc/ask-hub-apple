import Foundation
@testable import OrchestratorKit
import os
import Testing

private struct TestError: Error {}

private struct FakeGitHubState {
    var results: [Result<[ReadyDiscussion], TestError>]
    var removed: [String] = []
    var removeFails = false
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
