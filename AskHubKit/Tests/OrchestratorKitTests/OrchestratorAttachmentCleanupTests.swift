import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR のマージ後の添付の片付け（Discussion #669 の Q7）

extension OrchestratorTests {
    private static func marker(_ name: String, id: String) -> AttachmentMarker {
        AttachmentMarker(
            path: "files/\(id)/\(name)",
            sha: String(repeating: "b", count: 40),
            commit: String(repeating: "c", count: 40),
            name: name,
            size: 10,
            type: "image/png"
        )
    }

    private static let design = marker("design.png", id: "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    private static let answer = marker("answer.png", id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    private static let ask = marker("ask.png", id: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")
    private static let foreign = marker("foreign.png", id: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")

    private static func section(_ markers: [AttachmentMarker]) -> String {
        AttachmentSection.appending(markers, to: "本文", repository: "shilokuma-inc/ask-hub-apple")
    }

    private static let finalPullRequest = MergedEpicFinalPullRequest(
        repository: "shilokuma-inc/ask-hub-apple",
        number: 30,
        headBranch: "epic/mvp",
        author: "mrs1669",
        goalDiscussion: 12
    )

    private func prepare(_ github: FakeGitHub) {
        github.setMergedEpicFinalPullRequests([Self.finalPullRequest])
        github.setDiscussionTexts([
            AuthoredText(author: "mrs1669", body: Self.section([Self.design])),
            AuthoredText(author: "mrs1669", body: "回答: 案1\n\n" + Self.section([Self.answer])),
            // 信用しない author の目印は使わない（ほかの epic の添付を消させない）
            AuthoredText(author: "someone", body: Self.section([Self.foreign]))
        ], for: 12)
        github.setReviewComments([AuthoredText(author: "mrs1669", body: Self.section([Self.ask]))], base: "epic/mvp")
        github.setAttachmentBranchPaths([Self.design.path, Self.answer.path, Self.ask.path, Self.foreign.path, "README.md"])
    }

    @Test func deletesAttachmentsOfMergedEpicAndMarksFinalPullRequest() async throws {
        let github = FakeGitHub([.success([])])
        prepare(github)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())
        try await orchestrator.pollOnce()

        #expect(github.deletedAttachments == [[Self.design.path, Self.answer.path, Self.ask.path]])
        #expect(github.pullRequestComments.count == 1)
        let comment = try #require(github.pullRequestComments.first)
        #expect(comment.hasPrefix("shilokuma-inc/ask-hub-apple#30: <!-- ask-hub:attachments-cleaned {\"count\":3} -->"))
        #expect(logs.recorded.contains { $0.contains("添付 3 件を askhub/attachments から消しました") })

        // 片付けた PR は二度と処理しない
        try await orchestrator.pollOnce()
        #expect(github.deletedAttachments.count == 1)
    }

    @Test func skipsFinalPullRequestAlreadyMarked() async throws {
        let github = FakeGitHub([.success([])])
        prepare(github)
        github.setEpicFinalPullRequests([], comments: [
            30: [IssueComment(id: 1, author: "mrs1669", body: AttachmentCleanup.comment(deleted: 1, found: 1))]
        ])
        try await makeOrchestrator(github: github, runtime: FakeRuntime()).pollOnce()

        #expect(github.deletedAttachments.isEmpty)
        #expect(github.pullRequestComments.isEmpty)
    }

    @Test func ignoresMarkOfUntrustedAuthorAndFinalPullRequestOfUntrustedAuthor() async throws {
        let github = FakeGitHub([.success([])])
        prepare(github)
        // 信用しない author の「済んだ印」では止めない
        github.setEpicFinalPullRequests([], comments: [
            30: [IssueComment(id: 1, author: "someone", body: AttachmentCleanup.comment(deleted: 0, found: 0))]
        ])
        try await makeOrchestrator(github: github, runtime: FakeRuntime()).pollOnce()
        #expect(github.deletedAttachments.count == 1)

        // 信用しない author が作った最終 PR は扱わない
        let other = FakeGitHub([.success([])])
        prepare(other)
        other.setMergedEpicFinalPullRequests([
            MergedEpicFinalPullRequest(
                repository: "shilokuma-inc/ask-hub-apple", number: 31, headBranch: "epic/mvp", author: "someone", goalDiscussion: 12
            )
        ])
        try await makeOrchestrator(github: other, runtime: FakeRuntime()).pollOnce()
        #expect(other.deletedAttachments.isEmpty)
    }

    @Test func doesNotCommentWhenEpicHasNoAttachments() async throws {
        let github = FakeGitHub([.success([])])
        github.setMergedEpicFinalPullRequests([Self.finalPullRequest])
        github.setDiscussionTexts([AuthoredText(author: "mrs1669", body: "添付なし")], for: 12)
        try await makeOrchestrator(github: github, runtime: FakeRuntime()).pollOnce()

        #expect(github.deletedAttachments.isEmpty)
        #expect(github.pullRequestComments.isEmpty)
    }

    @Test func retriesOnNextPollWhenRefUpdateConflicts() async throws {
        let github = FakeGitHub([.success([])])
        prepare(github)
        github.setDeleteConflicts(1)
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())
        try await orchestrator.pollOnce()
        #expect(github.deletedAttachments.isEmpty)
        #expect(github.pullRequestComments.isEmpty)

        // 競合したら、間隔を待たずに次のポーリングでやり直す
        try await orchestrator.pollOnce()
        #expect(github.deletedAttachments.count == 1)
        #expect(github.pullRequestComments.count == 1)
    }

    @Test func checksMergedFinalPullRequestsAtMostHourly() async throws {
        let github = FakeGitHub([.success([])])
        let orchestrator = try makeOrchestrator(github: github, runtime: FakeRuntime())
        try await orchestrator.pollOnce()
        try await orchestrator.pollOnce()
        // 時刻が進まないので、2 回目のポーリングでは探さない
        #expect(github.mergedFinalPullRequestFetches == 1)
    }
}

struct AttachmentCleanupTests {
    private static let marker = AttachmentMarker(
        path: "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/a.png",
        sha: String(repeating: "b", count: 40),
        commit: String(repeating: "c", count: 40),
        name: "a.png",
        size: 1,
        type: "image/png"
    )

    @Test func collectsPathsOfTrustedAuthorsOnce() {
        let body = AttachmentSection.appending([Self.marker], to: "x", repository: "o/r")
        let paths = AttachmentCleanup.paths(
            in: [
                AuthoredText(author: "mrs1669", body: body),
                AuthoredText(author: "mrs1669", body: body),
                AuthoredText(author: nil, body: body)
            ],
            trustedAuthors: TrustedAuthors(["mrs1669"])
        )
        #expect(paths == [Self.marker.path])
    }

    @Test func cleanedMarkMustBeAtStartAndByTrustedAuthor() {
        let trusted = TrustedAuthors(["mrs1669"])
        let mark = AttachmentCleanup.comment(deleted: 2, found: 3)
        #expect(mark.hasPrefix("<!-- ask-hub:attachments-cleaned {\"count\":2} -->\n"))
        #expect(AttachmentCleanup.isCleaned([IssueComment(id: 1, author: "mrs1669", body: "\n" + mark)], trustedAuthors: trusted))
        #expect(!AttachmentCleanup.isCleaned([IssueComment(id: 1, author: "mrs1669", body: "前置き\n" + mark)], trustedAuthors: trusted))
        #expect(!AttachmentCleanup.isCleaned([IssueComment(id: 1, author: "someone", body: mark)], trustedAuthors: trusted))
    }
}
