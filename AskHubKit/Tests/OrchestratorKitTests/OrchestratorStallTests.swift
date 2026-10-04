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
}
