import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// 担当リポジトリの移管・改名への追従（Issue #757）
struct OrchestratorRepositoryRenameTests {
    let logs = LogRecorder()
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func renamesTransferredRepositoryInConfig() async throws {
        let github = FakeGitHub([.success([])])
        github.setRenamed("shilokuma-inc/quiz-ios", to: "tm-family/quiz-ios")
        let (orchestrator, store) = try makeOrchestrator(github: github)

        try await orchestrator.pollOnce()

        #expect(store.renamed == ["shilokuma-inc/quiz-ios → tm-family/quiz-ios"])
        let config = await orchestrator.config
        #expect(config.repositories.map(\.fullName) == ["shilokuma-inc/ask-hub-apple", "tm-family/quiz-ios"])
        #expect(config.repository(named: "tm-family/quiz-ios")?.checkoutPath == "/src/quiz-ios")
        // 移管先の organization も検索の対象になる
        #expect(config.orgs == ["shilokuma-inc", "tm-family"])
        #expect(logs.recorded.contains("shilokuma-inc/quiz-ios は tm-family/quiz-ios に移管・改名されています。設定の担当リポジトリの名前を書き換えました"))
        // 同じポーリングの担当の印から、新しい名前に書く
        #expect(github.heartbeats.map { String($0.prefix(while: { $0 != ":" })) } == ["shilokuma-inc/ask-hub-apple", "tm-family/quiz-ios"])
    }

    @Test func checksEachRepositoryAtMostEveryInterval() async throws {
        let github = FakeGitHub([.success([])])
        github.setCurrentNameFails(true)
        let (orchestrator, store) = try makeOrchestrator(github: github)

        // 確かめられなくても今の名前のまま動き、ログにも出さない
        try await orchestrator.pollOnce()
        #expect(github.checkedNames == ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/quiz-ios"])
        #expect(!logs.recorded.contains { $0.contains("移管・改名") })

        // 間隔より前は問い合わせない
        github.setCurrentNameFails(false)
        github.setRenamed("shilokuma-inc/quiz-ios", to: "tm-family/quiz-ios")
        clock.withLock { $0 = $0.addingTimeInterval(Orchestrator.repositoryNameCheckInterval - 1) }
        try await orchestrator.pollOnce()
        #expect(github.checkedNames.count == 2)
        #expect(store.renamed.isEmpty)

        clock.withLock { $0 = $0.addingTimeInterval(1) }
        try await orchestrator.pollOnce()
        #expect(store.renamed == ["shilokuma-inc/quiz-ios → tm-family/quiz-ios"])
    }

    @Test func ignoresCaseOnlyDifference() async throws {
        let github = FakeGitHub([.success([])])
        github.setRenamed("shilokuma-inc/quiz-ios", to: "Shilokuma-Inc/Quiz-iOS")
        let (orchestrator, store) = try makeOrchestrator(github: github)

        try await orchestrator.pollOnce()

        #expect(store.renamed.isEmpty)
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/quiz-ios")?.fullName == "shilokuma-inc/quiz-ios")
    }

    @Test func keepsConfigWhenNewNameIsAlreadyAssigned() async throws {
        let github = FakeGitHub([.success([])])
        github.setRenamed("shilokuma-inc/quiz-ios", to: "tm-family/quiz-ios")
        let (orchestrator, store) = try makeOrchestrator(
            github: github,
            extra: RepositoryConfig(owner: "tm-family", name: "quiz-ios", checkoutPath: "/src/tm-quiz-ios")
        )

        try await orchestrator.pollOnce()

        #expect(store.renamed.isEmpty)
        #expect(await orchestrator.config.repositories.count == 3)
        #expect(logs.recorded.contains(
            "shilokuma-inc/quiz-ios は tm-family/quiz-ios に移管・改名されていますが、tm-family/quiz-ios が既に担当リポジトリにあるため、設定を書き換えません。設定を手で直してください"
        ))
    }

    @Test func retriesRenameAfterIntervalWhenConfigCannotBeWritten() async throws {
        let github = FakeGitHub([.success([])])
        github.setRenamed("shilokuma-inc/quiz-ios", to: "tm-family/quiz-ios")
        let (orchestrator, store) = try makeOrchestrator(github: github)
        store.setRenameFails(true)

        try await orchestrator.pollOnce()
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/quiz-ios") != nil)
        #expect(logs.recorded.contains { $0.hasPrefix("shilokuma-inc/quiz-ios は tm-family/quiz-ios に移管・改名されていますが、設定を書き換えられませんでした") })

        store.setRenameFails(false)
        clock.withLock { $0 = $0.addingTimeInterval(Orchestrator.repositoryNameCheckInterval) }
        try await orchestrator.pollOnce()
        #expect(await orchestrator.config.repository(named: "tm-family/quiz-ios") != nil)
    }

    @Test func onlyLogsWithoutConfigStore() async throws {
        let github = FakeGitHub([.success([])])
        github.setRenamed("shilokuma-inc/quiz-ios", to: "tm-family/quiz-ios")
        let config = try Self.config(repositories: Self.repositories)
        let logs = logs
        let orchestrator = Orchestrator(
            config: config, github: github, inbox: FakeInbox(), runtime: FakeRuntime(), log: { logs.append($0) }
        )

        try await orchestrator.pollOnce()

        #expect(await orchestrator.config == config)
        #expect(logs.recorded.contains(
            "shilokuma-inc/quiz-ios は tm-family/quiz-ios に移管・改名されていますが、設定ファイルの場所が分からないため、書き換えられません。設定を手で直してください"
        ))
    }

    // MARK: - 補助

    private static let repositories = [
        RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
        RepositoryConfig(owner: "shilokuma-inc", name: "quiz-ios", checkoutPath: "/src/quiz-ios")
    ]

    private static func config(repositories: [RepositoryConfig]) throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: repositories,
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}"])
        )
    }

    private func makeOrchestrator(github: FakeGitHub, extra: RepositoryConfig? = nil) throws -> (Orchestrator, FakeConfigStore) {
        let config = try Self.config(repositories: Self.repositories + [extra].compactMap(\.self))
        let store = FakeConfigStore(config)
        let (logs, clock) = (logs, clock)
        let orchestrator = Orchestrator(
            config: config,
            github: github,
            inbox: FakeInbox(),
            runtime: FakeRuntime(),
            log: { logs.append($0) },
            now: { clock.withLock { $0 } },
            configStore: store
        )
        return (orchestrator, store)
    }
}
