import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// ready-for-loop の付いた、手で回す Discussion（manual-loop）の扱い
extension OrchestratorTests {
    @Test func doesNotLaunchManualLoopDiscussion() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12, isManualLoop: true)])])
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.launched.isEmpty)
        // ready-for-loop は外さない（手で回すループが始めるときに外す）
        #expect(github.removed.isEmpty)
        #expect(logs.recorded.contains(
            "shilokuma-inc/ask-hub-apple#12 は起動しません: manual-loop（手で回す）が付いています。ループは手で始めてください"
        ))
    }

    @Test func doesNotLaunchOtherDiscussionWhileManualLoopEpicIsOpen() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 10, author: "mrs1669")])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()

        #expect(runtime.launched.isEmpty)
        #expect(logs.recorded.contains(
            "shilokuma-inc/ask-hub-apple#12 は起動しません: 同じリポジトリの Discussion #10 を手で回しています（manual-loop）。その epic が終わるまで自動では起動しません"
        ))

        // 手で回す Discussion が閉じられたら（最終 PR のマージ）、起動する
        github.setManualLoops([])
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
    }
}
