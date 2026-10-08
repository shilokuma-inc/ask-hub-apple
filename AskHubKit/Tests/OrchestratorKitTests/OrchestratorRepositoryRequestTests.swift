import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

struct OrchestratorRepositoryRequestTests {
    let logs = LogRecorder()

    static let hub = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    static let notti = RepositoryConfig(owner: "shilokuma-inc", name: "notti-ios", checkoutPath: "/src/notti-ios")
    static let commands = RepositoryCommands(create: ["/bin/create"], remove: ["/bin/remove"], newCheckoutDirectory: "/src")

    static let createRequest = RepositoryRequest.create(NewRepository(
        repository: "shilokuma-inc/my-quiz-ios",
        template: .quiz,
        appName: "MyQuiz",
        bundleIdentifier: "jp.shilokuma.MyQuiz"
    ))

    static func removeRequest(force: Bool = false, deletesLocalFiles: Bool = true) -> RepositoryRequest {
        .remove(RepositoryRemoval(repository: "shilokuma-inc/notti-ios", deletesLocalFiles: deletesLocalFiles, force: force))
    }

    static func issue(
        _ request: RepositoryRequest,
        in repository: String,
        number: Int = 5,
        author: String = "mrs1669"
    ) -> RepositoryRequestIssue {
        .fixture(repository: repository, number: number, author: author, title: request.title, body: request.body)
    }

    func makeOrchestrator(
        github: FakeGitHub,
        runtime: FakeRuntime,
        repositories: [RepositoryConfig] = [hub, notti]
    ) throws -> (Orchestrator, FakeConfigStore) {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: repositories,
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}"]),
            repositoryCommands: Self.commands
        )
        let store = FakeConfigStore(config)
        let logs = logs
        let orchestrator = Orchestrator(
            config: config,
            github: github,
            inbox: FakeInbox(),
            runtime: runtime,
            log: { logs.append($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            configStore: store
        )
        return (orchestrator, store)
    }

    // MARK: - 作成

    @Test func createsRepositoryAddsItAndReportsOnIssue() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.createRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ログ /Users/me/src\nASKHUB_RESULT: develop に push しました\n")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        let expected = [
            "/bin/create", "shilokuma-inc/template-quiz-app-ios", "shilokuma-inc/my-quiz-ios",
            "MyQuiz", "jp.shilokuma.MyQuiz", "/src/my-quiz-ios", "public"
        ]
        #expect(runtime.ran == [expected])
        #expect(store.added == ["shilokuma-inc/my-quiz-ios /src/my-quiz-ios"])
        // 作ったリポジトリは、すぐに担当リポジトリとして扱う
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/my-quiz-ios") != nil)
        let comment = try #require(github.ideaComments.first)
        #expect(comment.hasPrefix("#5: shilokuma-inc/my-quiz-ios をクイズのテンプレートから作りました"))
        #expect(comment.contains("- develop に push しました"))
        #expect(comment.contains("App Store Connect"))
        // コマンドのほかの出力（ローカルのパスを含みうる）は書かない
        #expect(!comment.contains("/Users/me"))
        #expect(github.closedIdeas == [5])

        // 検索の反映が遅れて同じ依頼が出ても、作り直さない
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
    }

    @Test func createsWithoutCloningWhenRequested() async throws {
        let request = RepositoryRequest.create(NewRepository(
            repository: "shilokuma-inc/side-app-ios",
            template: .standard,
            appName: "SideApp",
            bundleIdentifier: "jp.shilokuma.SideApp",
            clonesToOrchestrator: false,
            isPrivate: true
        ))
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(request, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        // checkout のパスは空で、private を選べば private で作る
        #expect(runtime.ran.first?.suffix(2) == ["", "private"])
        #expect(store.added.isEmpty)
        #expect(github.ideaComments.first?.contains("担当 PC には clone していません") == true)
        #expect(github.closedIdeas == [5])
    }

    @Test func reportsPreconditionFailureWithoutRetrying() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.createRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 3, output: "ASKHUB_ERROR: shilokuma-inc/my-quiz-ios は既にあります\n")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == 1)
        #expect(store.added.isEmpty)
        #expect(github.ideaComments == [
            "#5: 依頼を処理できませんでした: shilokuma-inc/my-quiz-ios は既にあります\n"
                + "直したら、この Issue を閉じて AskHub から依頼し直してください。（askhub-orchestrator）"
        ])
        #expect(github.closedIdeas.isEmpty)
    }

    @Test func retriesFailedCommandOnceThenReports() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.createRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 1, output: "network down")])
        let (orchestrator, _) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.ideaComments.isEmpty)
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == RepositoryRequestTracker.maxAttempts)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.contains("createRepositoryCommand が終了コード 1 で終わりました") == true)
    }

    @Test func ignoresUntrustedUnassignedOrUnreadableRequests() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([
            Self.issue(Self.createRequest, in: "shilokuma-inc/ask-hub-apple", number: 1, author: "someone"),
            Self.issue(Self.createRequest, in: "shilokuma-inc/other-ios", number: 2),
            .fixture(repository: "shilokuma-inc/ask-hub-apple", number: 3, title: "【新規アプリ】x", body: "目印なし")
        ])
        let runtime = FakeRuntime()
        let (orchestrator, _) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        // 信用する author の、読めない依頼だけは理由を返す
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.hasPrefix("#3: 依頼を処理できませんでした: 本文の先頭に依頼の目印") == true)
    }

    @Test func rejectsCreatingRepositoryThatIsAlreadyAssigned() async throws {
        let request = RepositoryRequest.create(NewRepository(
            repository: "shilokuma-inc/notti-ios",
            template: .standard,
            appName: "Notti",
            bundleIdentifier: "jp.shilokuma.Notti"
        ))
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(request, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        let (orchestrator, _) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(github.ideaComments.first?.contains("既にこの PC の担当リポジトリです") == true)
    }

    // MARK: - 削除

    @Test func removesRepositoryDeletesLocalFilesAndHeartbeat() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.removeRequest(), in: "shilokuma-inc/notti-ios")])
        github.setLoopStatusIssues([
            LoopStatusIssueRecord(number: 101, author: "mrs1669", isOpen: true, updatedAt: .distantPast, body: "")
        ])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: 約 4.2 GB を消しました\n")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran == [["/bin/remove", "/src/notti-ios", "/src/notti-ralph-ctl"]])
        #expect(store.removed == ["shilokuma-inc/notti-ios"])
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/notti-ios") == nil)
        #expect(github.deletedHeartbeats == ["shilokuma-inc/notti-ios"])
        // ステータスタブに行を残さないよう、状態用の Issue も閉じる
        #expect(github.closedLoopStatusIssues == ["shilokuma-inc/notti-ios#101"])
        let comment = try #require(github.ideaComments.first)
        #expect(comment.hasPrefix("#5: shilokuma-inc/notti-ios をこの PC の担当リポジトリから外しました"))
        #expect(comment.contains("- 約 4.2 GB を消しました"))
        #expect(github.closedIdeas == [5])
    }

    @Test func removesFromConfigOnlyWhenLocalFilesAreKept() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.removeRequest(deletesLocalFiles: false), in: "shilokuma-inc/notti-ios")])
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(store.removed == ["shilokuma-inc/notti-ios"])
        #expect(github.closedIdeas == [5])
    }

    @Test func passesForceToRemoveCommand() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.removeRequest(force: true), in: "shilokuma-inc/notti-ios")])
        let runtime = FakeRuntime()
        // ループの state ファイルが残っていても（プロセスが居なければ）、強制なら外す
        runtime.set(LoopStatus(stateFileExists: true, processAlive: false))
        let (orchestrator, _) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.contains(["/bin/remove", "--force", "/src/notti-ios", "/src/notti-ralph-ctl"]))
    }

    @Test func refusesToRemoveWhileLoopIsRunning() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.removeRequest(force: true), in: "shilokuma-inc/notti-ios")])
        let runtime = FakeRuntime()
        runtime.set(LoopStatus(stateFileExists: true, processAlive: true))
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(!runtime.ran.contains { $0.first == "/bin/remove" })
        #expect(store.removed.isEmpty)
        #expect(github.ideaComments.first?.contains("ループが動いています") == true)
    }

    @Test func refusesToRemoveFromAnotherRepositoryOrTheLastOne() async throws {
        let github = FakeGitHub([.success([])])
        // 外すリポジトリとは別のリポジトリの Issue
        github.setRepositoryRequests([Self.issue(Self.removeRequest(), in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)
        try await orchestrator.pollOnce()
        #expect(github.ideaComments.first?.contains("外したいリポジトリ（shilokuma-inc/notti-ios）に作ってください") == true)

        let lastGitHub = FakeGitHub([.success([])])
        lastGitHub.setRepositoryRequests([Self.issue(Self.removeRequest(), in: "shilokuma-inc/notti-ios")])
        let (last, lastStore) = try makeOrchestrator(github: lastGitHub, runtime: FakeRuntime(), repositories: [Self.notti])
        try await last.pollOnce()
        #expect(lastGitHub.ideaComments.first?.contains("最後の担当リポジトリは外せません") == true)
        #expect(store.removed.isEmpty)
        #expect(lastStore.removed.isEmpty)
    }

    @Test func keepsLocalFilesWhenRemoveCommandFindsUnpushedWork() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.removeRequest(), in: "shilokuma-inc/notti-ios")])
        let runtime = FakeRuntime()
        let output = """
            ASKHUB_ERROR: ブランチ feat/x に push していないコミットがあります
            ASKHUB_ERROR: 消さずに残しました
            """
        runtime.setRunResults([CommandResult(status: 3, output: output)])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        // 消せなければ担当からも外さない
        #expect(store.removed.isEmpty)
        #expect(github.ideaComments.first?.contains("ブランチ feat/x に push していないコミットがあります / 消さずに残しました") == true)
        #expect(github.closedIdeas.isEmpty)
    }
}
