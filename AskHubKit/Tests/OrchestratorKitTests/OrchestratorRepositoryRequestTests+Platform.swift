import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

/// プラットフォーム（iOS / visionOS）ごとのテンプレートからの作成
extension OrchestratorRepositoryRequestTests {
    @Test func createsVisionOSRepositoryFromVisionOSTemplate() async throws {
        let request = RepositoryRequest.create(NewRepository(
            repository: "shilokuma-vision/my-app-visionos",
            template: .visionOSStandard,
            appName: "MyApp",
            bundleIdentifier: "jp.shilokuma.MyApp"
        ))
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([Self.issue(request, in: "shilokuma-inc/ask-hub-apple")])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 0, output: "ASKHUB_RESULT: develop に push しました\n")])
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        // プラットフォームで処理を分けず、同じコマンドに visionOS のテンプレートを渡す
        let expected = [
            "/bin/create", "shilokuma-vision/template-app-visionos", "shilokuma-vision/my-app-visionos",
            "MyApp", "jp.shilokuma.MyApp", "/src/my-app-visionos", "public"
        ]
        #expect(runtime.ran == [expected])
        #expect(store.added == ["shilokuma-vision/my-app-visionos /src/my-app-visionos"])
        let comment = try #require(github.ideaComments.first)
        #expect(comment.hasPrefix("#5: shilokuma-vision/my-app-visionos を visionOS の通常のテンプレートから作りました"))
        #expect(github.closedIdeas == [5])
    }

    @Test func rejectsRequestWhosePlatformDoesNotMatchTemplate() async throws {
        let marker = #"<!-- ask-hub:repo-request {"action":"create","appName":"MyApp","platform":"visionos","#
            + #""repository":"shilokuma-vision/my-app-visionos","template":"shilokuma-inc/template-app-ios"} -->"#
        let github = FakeGitHub([.success([])])
        github.setRepositoryRequests([
            .fixture(repository: "shilokuma-inc/ask-hub-apple", number: 7, title: "【新規アプリ】shilokuma-vision/my-app-visionos", body: marker)
        ])
        let runtime = FakeRuntime()
        let (orchestrator, store) = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        // 今までの不正な依頼と同じく、作らずに理由を 1 回だけコメントして開いたままにする
        #expect(runtime.ran.isEmpty)
        #expect(store.added.isEmpty)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.hasPrefix("#7: 依頼を処理できませんでした: 本文の先頭に依頼の目印") == true)
        #expect(github.closedIdeas.isEmpty)
    }
}
