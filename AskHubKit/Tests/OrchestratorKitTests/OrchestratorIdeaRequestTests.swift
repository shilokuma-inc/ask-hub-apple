import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

// MARK: - 新機能の依頼

extension OrchestratorTests {
    private static let created = CommandResult(
        status: 0,
        output: "考察しました\nASKHUB_DISCUSSION_URL: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12\n"
    )

    @Test func createsDiscussionForIdeaRequestThenCommentsAndCloses() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()

        let arguments = try #require(runtime.ran.first)
        #expect(arguments.first == "claude")
        #expect(arguments[2].contains("依頼 Issue: #7"))
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.hasPrefix("#7: 質問付きの Discussion を作りました: https://github.com/shilokuma-inc/ask-hub-apple/discussions/12") == true)
        #expect(github.closedIdeas == [7])

        // 検索の反映が遅れて同じ依頼が出ても、作り直さずコメントもしない
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
        #expect(github.ideaComments.count == 1)
    }

    @Test func ignoresUntrustedOrUnassignedIdeaRequests() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 1, author: "someone"), .fixture(repository: "shilokuma-inc/notti-ios", number: 2)])
        let runtime = FakeRuntime()
        try await makeOrchestrator(github: github, runtime: runtime).pollOnce()

        #expect(runtime.ran.isEmpty)
        #expect(github.ideaComments.isEmpty)
    }

    @Test func retriesOnceThenReportsFailureOnIssue() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        let runtime = FakeRuntime()
        runtime.setRunResults([CommandResult(status: 1, output: "error")])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.ideaComments.isEmpty)
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()

        #expect(runtime.ran.count == IdeaRequestTracker.maxAttempts)
        #expect(github.ideaComments.count == 1)
        #expect(github.ideaComments.first?.hasPrefix("#7: 質問付きの Discussion を作れませんでした") == true)
        #expect(github.closedIdeas.isEmpty)
    }

    @Test func retriesOnlyCompletionWhenCommentFails() async throws {
        let github = FakeGitHub([.success([])])
        github.setIdeaIssues([.fixture(number: 7)])
        github.setIdeaCompletionFails(true)
        let runtime = FakeRuntime()
        runtime.setRunResults([Self.created])
        let orchestrator = try makeOrchestrator(github: github, runtime: runtime)

        try await orchestrator.pollOnce()
        #expect(github.closedIdeas.isEmpty)

        // Discussion は作り直さず、コメントとクローズだけを再試行する
        github.setIdeaCompletionFails(false)
        try await orchestrator.pollOnce()
        #expect(runtime.ran.count == 1)
        #expect(github.closedIdeas == [7])
    }
}
