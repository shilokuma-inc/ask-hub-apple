import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 異常終了したループの再開

extension OrchestratorTests {
    private static let stalled = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)

    @Test func resumesStalledLoopWithoutDiscussion() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.set(Self.stalled)
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: "## メモ\n"))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        // 再開したループが動いている間は起動し直さない
        try await orchestrator.pollOnce()

        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple のループがタスクを残して止まっていたので、再開しました（1/3 回目）"))
    }

    @Test func resumesStalledLoopBeforeLaunchingReadyDiscussion() async throws {
        let discussion = ReadyDiscussion.fixture(number: 5)
        let github = FakeGitHub([.success([discussion])])
        let runtime = FakeRuntime()
        runtime.set(Self.stalled)
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        // 途中の epic を再開し、新しい Discussion のループは起動しない
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
    }

    @Test func doesNotLaunchReadyDiscussionWhenResumingStalledLoopFails() async throws {
        let github = FakeGitHub([.success([ReadyDiscussion.fixture(number: 5)])])
        let runtime = FakeRuntime()
        runtime.set(Self.stalled)
        runtime.setLaunchFails(true)
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        let decisions = try await orchestrator.pollOnce()

        #expect(decisions == [.skip(ReadyDiscussion.fixture(number: 5), .loopStateRemains)])
    }

    @Test func stopsResumingStalledLoopThatMakesNoProgress() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        for _ in 0...StallWatcher.maxAttempts + 1 {
            // 起動してもすぐ落ちる
            runtime.set(Self.stalled)
            try await orchestrator.pollOnce()
        }

        #expect(runtime.launched.count == StallWatcher.maxAttempts)
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple のループが進まないまま 3 回止まったので、自動の再開をやめます（ループのログを確認してください）"))
    }

    @Test func waitsForEpicInProgressWithoutCountingFailuresThenLaunches() async throws {
        let github = FakeGitHub([.success([ReadyDiscussion.fixture(number: 5)])])
        let runtime = FakeRuntime()
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil, loopPrepared: true))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 途中の epic がある間は、何回ポーリングしても起動しない（起動の失敗として数えない）
        for _ in 0...LaunchTracker.maxAttempts {
            try await orchestrator.pollOnce()
        }
        #expect(runtime.launched.isEmpty)

        // epic が終われば起動する
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [x] 【FEAT】A", state: nil, loopPrepared: true))
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "5"]])
    }
}
