import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 担当に入れる依頼（repo-request の add）の処理
extension OrchestratorRepositoryRequestTests {
    static let addRequest = RepositoryRequest.add(RepositoryAddition(repository: "shilokuma-inc/my-app-ios"))
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func addsExistingRepositoryAndReportsOnIssue() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([
            CommandResult(
                status: 0,
                output: "Cloning into '/Users/me/src/my-app-ios'...\nASKHUB_RESULT: ralph-kit の中継を develop に push しました\n"
            )
        ])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        // 決まった場所の checkout と、kit の場所を得るための依頼を受けた担当リポジトリの checkout を渡し、担当リポジトリで実行する
        #expect(runtime.ran == [["/bin/add", "shilokuma-inc/my-app-ios", "/src/my-app-ios", "/src/ask-hub-apple"]])
        #expect(runtime.ranFor == ["shilokuma-inc/ask-hub-apple"])
        #expect(store.added == ["shilokuma-inc/my-app-ios /src/my-app-ios"])
        // 加えたリポジトリは、すぐに担当リポジトリとして扱う
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/my-app-ios") != nil)
        let comment = try #require(github.ideaComments.first)
        #expect(comment.hasPrefix("#5: shilokuma-inc/my-app-ios をこの PC の担当リポジトリに加えました"))
        #expect(comment.contains("- ralph-kit の中継を develop に push しました"))
        // コマンドのほかの出力（ローカルのパスを含みうる）は書かない
        #expect(!comment.contains("/Users/me"))
        #expect(!comment.contains("/src/"))
        #expect(github.closedIdeas == [5])

        // 検索の反映が遅れて同じ依頼が出ても、用意し直さない
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
    }

    @Test func rejectsAddingRepositoryThatIsAlreadyAssignedHere() async throws {
        let request = RepositoryRequest.add(RepositoryAddition(repository: "Shilokuma-Inc/Notti-iOS"))
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(request, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(store.added.isEmpty)
        #expect(github.ideaComments.first?.contains("既にこの PC の担当リポジトリです") == true)
    }

    @Test func rejectsAddingRepositoryAssignedToAnotherPC() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        // 30 分以内に書かれた担当の印がある
        github.setHeartbeatLastSeen(Self.now.addingTimeInterval(-29 * 60), in: "shilokuma-inc/my-app-ios")
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(store.added.isEmpty)
        // やり直しても変わらないので、1 回だけ理由を返す
        #expect(github.ideaComments == [
            "#5: 依頼を処理できませんでした: 別の PC が担当しています（最終確認: 2027-01-15T07:31:00Z）。"
                + "先にその PC の担当から外してから、依頼し直してください\n"
                + "直したら、この Issue を閉じて AskHub から依頼し直してください。（askhub-orchestrator）"
        ])
        #expect(github.closedIdeas.isEmpty)
    }

    @Test func addsRepositoryWhoseHeartbeatIsStale() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        // 担当の印が 30 分より古い（前の PC はもう動いていない）
        github.setHeartbeatLastSeen(Self.now.addingTimeInterval(-31 * 60), in: "shilokuma-inc/my-app-ios")
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == 1)
        #expect(store.added == ["shilokuma-inc/my-app-ios /src/my-app-ios"])
    }

    @Test func retriesWhenHeartbeatCannotBeRead() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        github.setHeartbeatLastSeen(nil, in: "shilokuma-inc/my-app-ios", fails: true)
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        // 読めないうちは断らず、次のポーリングでやり直す
        #expect(github.ideaComments.isEmpty)

        github.setHeartbeatLastSeen(nil, in: "shilokuma-inc/my-app-ios")
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == 1)
        #expect(store.added == ["shilokuma-inc/my-app-ios /src/my-app-ios"])
    }

    @Test func reportsPreconditionFailureOfAddCommandWithoutAdding() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 3, output: "ASKHUB_ERROR: shilokuma-inc/my-app-ios に develop ブランチがありません\n")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == 1)
        #expect(store.added.isEmpty)
        #expect(await orchestrator.config.repository(named: "shilokuma-inc/my-app-ios") == nil)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.contains("shilokuma-inc/my-app-ios に develop ブランチがありません") == true)
    }

    @Test func retriesFailedAddCommandThenReports() async throws {
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(Self.addRequest, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 1, output: "network down")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        for _ in 0..<RepositoryRequestTracker.maxAttempts {
            try await orchestrator.pollOnce()
        }

        #expect(runtime.ran.count == RepositoryRequestTracker.maxAttempts)
        #expect(store.added.isEmpty)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.contains("addRepositoryCommand が終了コード 1 で終わりました") == true)
    }
}
