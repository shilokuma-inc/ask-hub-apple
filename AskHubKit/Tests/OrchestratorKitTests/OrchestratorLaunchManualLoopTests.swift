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
}
