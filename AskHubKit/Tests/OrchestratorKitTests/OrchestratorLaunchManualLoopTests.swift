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

    @Test func skipsOnlyLaunchesWhenManualLoopSearchFails() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        github.setManualLoopsFail(true)
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()

        // 手で回す epic を確かめられなければ起動しないが、ループの状態の書き出しなどの後処理は続ける
        #expect(runtime.launched.isEmpty)
        #expect(logs.recorded.contains { $0.hasPrefix("manual-loop の Discussion を検索できませんでした") })
        #expect(github.createdLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])

        github.setManualLoopsFail(false)
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
    }
}

extension FakeGitHub {
    func manualLoopDiscussions(orgs: [String]) async throws -> [ManualLoopDiscussion] {
        try state.withLock { state in
            if state.manualLoopsFail {
                throw TestError()
            }
            return state.manualLoops.filter { discussion in
                orgs.contains { discussion.repository.lowercased().hasPrefix($0.lowercased() + "/") }
            }
        }
    }

    func setManualLoopsFail(_ fails: Bool) {
        state.withLock { $0.manualLoopsFail = fails }
    }

    func setManualLoops(_ discussions: [ManualLoopDiscussion]) {
        state.withLock { $0.manualLoops = discussions }
    }
}
