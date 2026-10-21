import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 依頼先のリポジトリの Discussions の確認（Issue #719）

extension OrchestratorTests {
    private static let hub = "shilokuma-inc/ask-hub-apple"
    private static let created = CommandResult(
        status: 0,
        output: "考察しました\nASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12\n"
    )

    @Test func enablesDisabledDiscussionsBeforeCreatingDiscussion() async throws {
        // テンプレートから作ったリポジトリは Discussions が無効のまま
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        github.setDiscussionSettings(DiscussionSettings(isEnabled: false, categories: []), in: Self.hub)
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(github.enabledDiscussions == [Self.hub])
        #expect(runtime.ran.count == 1)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.hasPrefix("#7: 質問付きの Discussion を作りました") == true)
        #expect(github.closedIdeas == [7])
    }

    @Test func waitsWithoutClaudeUntilIdeasCategoryExists() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        github.setDiscussionSettings(DiscussionSettings(isEnabled: true, categories: ["General"]), in: Self.hub)
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        // claude は起動せず（試行に数えない）、理由は 1 回だけ書く。Discussions は既に有効なので触らない
        #expect(runtime.ran.isEmpty)
        #expect(github.enabledDiscussions.isEmpty)
        #expect(github.ideaComments == [
            "#7: 質問付きの Discussion を作れません: \(IdeaDiscussionProblem.missingCategory.message(for: Self.hub))\n"
                + "直ると、次のポーリングで Discussion を作ります（依頼を出し直す必要はありません）。（askhub-orchestrator）"
        ])

        // カテゴリができたら、依頼を出し直さなくても続きから作る
        github.setDiscussionSettings(DiscussionSettings(isEnabled: true, categories: ["General", "Ideas"]), in: Self.hub)
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
        #expect(github.closedIdeas == [7])
    }

    @Test func reportsOnceWhenDiscussionsCannotBeEnabled() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        github.setDiscussionSettings(DiscussionSettings(isEnabled: false, categories: []), in: Self.hub)
        github.setEnableDiscussionsFails(true)
        let runtime = FakeRuntime()
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.contains(IdeaDiscussionProblem.disabled.message(for: Self.hub)) == true)
        // 書いた後は、ポーリングごとに有効にし直さない（ログも重ねない）
        #expect(logs.recorded.filter { $0.contains("Discussions を有効にできませんでした") }.count == 1)
    }

    @Test func skipsBlockedRequestAndCreatesNextOne() async throws {
        let notti = "shilokuma-inc/notti-ios"
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7), .fixture(repository: notti, number: 3)])
        github.setDiscussionSettings(DiscussionSettings(isEnabled: true, categories: []), in: Self.hub)
        let runtime = FakeRuntime()
        runtime.setRunResults([
            CommandResult(status: 0, output: "ASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/notti-ios/discussions/4\n")
        ])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime, repositories: [
            RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
            RepositoryConfig(owner: "shilokuma-inc", name: "notti-ios", checkoutPath: "/src/notti-ios")
        ])

        try await orchestrator.pollOnce()

        // 先の依頼（ask-hub-apple）で作れなくても、同じポーリングで次の依頼（notti-ios）を処理する
        #expect(runtime.ran.count == 1)
        #expect(github.ideaComments.count == 2)
        #expect(github.ideaComments.first?.hasPrefix("#7: 質問付きの Discussion を作れません") == true)
        #expect(github.ideaComments.last?.hasPrefix("#3: 質問付きの Discussion を作りました") == true)
        #expect(github.closedIdeas == [3])
    }

    @Test func skipsRequestWhenSettingsCannotBeRead() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        github.setDiscussionSettingsFails(true)
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        // 確かめられないときは、claude を起動せず、依頼 Issue にも書かずに次のポーリングを待つ
        try await orchestrator.pollOnce()
        #expect(runtime.ran.isEmpty)
        #expect(github.ideaComments.isEmpty)

        github.setDiscussionSettingsFails(false)
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
        #expect(github.closedIdeas == [7])
    }
}
