import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - 担当の印

extension OrchestratorTests {
    @Test func writesHeartbeatAtMostEveryInterval() async throws {
        let github = FakeGitHub([.success([])])
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime()) { clock.withLock { $0 } }

        try await orchestrator.pollOnce()
        #expect(github.heartbeats == [
            "shilokuma-inc/ask-hub-apple: " + OrchestratorHeartbeat.description(at: Date(timeIntervalSince1970: 1_800_000_000))
        ])

        // 間隔より前は書き直さない
        clock.withLock { $0 = $0.addingTimeInterval(OrchestratorHeartbeat.updateInterval - 1) }
        try await orchestrator.pollOnce()
        #expect(github.heartbeats.count == 1)

        clock.withLock { $0 = $0.addingTimeInterval(1) }
        try await orchestrator.pollOnce()
        #expect(github.heartbeats.count == 2)
    }

    @Test func retriesHeartbeatOnNextPollWhenWritingFails() async throws {
        let github = FakeGitHub([.success([])])
        github.setHeartbeatFails(true)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())

        // 書けなくてもほかの判定は続け、次のポーリングで書き直す
        try await orchestrator.pollOnce()
        #expect(github.heartbeats.isEmpty)
        #expect(logs.recorded.first?.hasPrefix("shilokuma-inc/ask-hub-apple に担当の印を書けませんでした") == true)

        github.setHeartbeatFails(false)
        try await orchestrator.pollOnce()
        #expect(github.heartbeats.count == 1)
    }
}
