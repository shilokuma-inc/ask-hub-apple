import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct OrchestratorConfigReloadTests {
    let logs = LogRecorder()

    @Test func reloadsConfigEveryPollAndKeepsPreviousOnFailure() async throws {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}"])
        )
        let store = FakeConfigStore(config)
        let logs = logs
        let orchestrator = Orchestrator(
            config: config,
            github: FakeGitHub([.success([])]),
            inbox: FakeInbox(),
            runtime: FakeRuntime(),
            log: { logs.append($0) },
            configStore: store
        )

        // 手で設定を書き換えた
        try store.addRepository("shilokuma-inc/zankyo-apple", checkoutPath: "/src/zankyo-apple")
        try await orchestrator.pollOnce()
        #expect(await orchestrator.config.repositories.count == 2)
        #expect(logs.recorded.contains("設定を読み直しました（担当リポジトリの追加: shilokuma-inc/zankyo-apple）"))

        // 読めなければ前の設定のまま。同じ失敗は 1 回だけログに出す
        store.setLoadFails(true)
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()
        #expect(await orchestrator.config.repositories.count == 2)
        #expect(logs.recorded.filter { $0.hasPrefix("設定を読み直せませんでした") }.count == 1)
    }
}
