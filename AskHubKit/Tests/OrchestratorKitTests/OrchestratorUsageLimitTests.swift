import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - Claude の利用上限

extension OrchestratorTests {
    private static let stalledLoop = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)
    private static let unfinishedEpic = EpicSnapshot(branch: "epic/mvp", goal: "- [ ] 【FEAT】A", state: nil, loopPrepared: true)

    @Test func waitsForUsageLimitResetThenResumesWithoutCounting() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([ReadyDiscussion.fixture(number: 5)])])
        let runtime = FakeRuntime()
        runtime.set(Self.stalledLoop)
        runtime.setEpic(Self.unfinishedEpic)
        let reset = clock.now.addingTimeInterval(2 * 60 * 60)
        runtime.setUsageLimitReset(reset)
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        // 解除まではループを再開・起動せず、担当の印に解除の時刻を書く
        for _ in 0...StallWatcher.maxAttempts {
            #expect(try await orchestrator.pollOnce().isEmpty)
        }
        #expect(runtime.launched.isEmpty)
        #expect(github.heartbeats.last?.hasSuffix(OrchestratorHeartbeat.description(at: clock.now, usageLimitedUntil: reset)) == true)
        #expect(logs.recorded.contains { $0.hasPrefix("Claude の利用上限に達しているので") })

        // 解除の時刻を過ぎたら再開する（上限で止まった分は数えない）
        clock.now = reset.addingTimeInterval(60)
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", ""]])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple のループがタスクを残して止まっていたので、再開しました（1/3 回目）"))
        #expect(logs.recorded.contains("Claude の利用上限が解除されたので、ループの起動・再開を再開します"))
        #expect(github.heartbeats.last?.hasSuffix(OrchestratorHeartbeat.description(at: clock.now)) == true)
    }

    @Test func doesNotCountIdeaCommandFailureByUsageLimit() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        let runtime = FakeRuntime()
        let reset = Int(clock.now.timeIntervalSince1970) + 3600
        runtime.setRunResults([CommandResult(status: 1, output: "Claude AI usage limit reached|\(reset)")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, now: { clock.now })

        try await orchestrator.pollOnce()
        // 失敗に数えず、上限の間は作り直さない
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
        #expect(github.ideaComments.isEmpty)
        #expect(logs.recorded.contains { $0.contains("利用上限で終わりました。解除の後に作り直します") })
    }
}

/// テストで進める時計
final class TestClock: Sendable {
    private let value: OSAllocatedUnfairLock<Date>

    init(_ date: Date) {
        value = OSAllocatedUnfairLock(initialState: date)
    }

    var now: Date {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
