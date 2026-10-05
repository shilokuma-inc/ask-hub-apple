import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 固まったループ

extension OrchestratorTests {
    @Test func terminatesHungLoopThenResumesIt() async throws {
        let github = FakeGitHub([.success([])])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil, loopPrepared: true))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hung = HungLoop(pid: 4242, iterationStartedAt: now.addingTimeInterval(-100 * 60))
        runtime.setHungLoop(hung)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { now })

        try await orchestrator.pollOnce()

        // 固まったプロセスを止め、同じポーリングで異常終了したループとして再開する
        #expect(runtime.terminated == [hung])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple のループ（PID 4242）の今の周回が 100 分進んでいないので、固まったとみなして止めます"))
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
    }

    @Test func resumesTerminatedLoopEvenWhenReadyDiscussionSearchFails() async throws {
        // ready-for-loop の検索が失敗しても、止めたループは再開する
        let github = FakeGitHub([.failure(TestError())])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        runtime.setEpic(EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil, loopPrepared: true))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        runtime.setHungLoop(HungLoop(pid: 4242, iterationStartedAt: now.addingTimeInterval(-100 * 60)))
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { now })

        await #expect(throws: TestError.self) {
            try await orchestrator.pollOnce()
        }
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
    }
}
