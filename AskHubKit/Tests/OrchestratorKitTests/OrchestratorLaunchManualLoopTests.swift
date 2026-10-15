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

    @Test func launchesOneAutomaticLoopWhileManualLoopEpicIsOpen() async throws {
        // 手で回している #10（ready-for-loop も残っている）と、自動で回す #12・#14
        let ready: [ReadyDiscussion] = [.fixture(number: 10, isManualLoop: true), .fixture(number: 12), .fixture(number: 14)]
        let github = FakeGitHub([.success(ready)])
        github.setManualLoops([ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 10, author: "mrs1669")])
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()

        // 手動ループがあるリポジトリでも、自動ループは 1 つ起動する（Discussion #425）。手で回す #10 は起動しない
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
        #expect(logs.recorded.contains(
            "shilokuma-inc/ask-hub-apple#10 は起動しません: manual-loop（手で回す）が付いています。ループは手で始めてください"
        ))
        #expect(!logs.recorded.contains { $0.contains("を手で回しています") })

        // 自動ループが動いている間は、手動ループの有無にかかわらず 2 つ目を起動しない（リポジトリに 1 つ）
        try await orchestrator.pollOnce()
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
    }

    @Test func launchesEvenWhenManualLoopSearchFails() async throws {
        let github = FakeGitHub([.success([.fixture(number: 12)])])
        github.setManualLoopsFail(true)
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()

        // 起動の判定は手動ループを見ないので、manual-loop の Discussion を検索できなくても起動する。ループの状態の書き出しなども続ける
        #expect(runtime.launched == [["/usr/local/bin/start-loop", "shilokuma-inc/ask-hub-apple", "12"]])
        #expect(logs.recorded.contains { $0.hasPrefix("manual-loop の Discussion を検索できませんでした") })
        #expect(github.createdLoopStatusIssues == ["shilokuma-inc/ask-hub-apple#101"])
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
