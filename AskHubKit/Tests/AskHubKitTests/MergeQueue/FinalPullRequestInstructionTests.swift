@testable import AskHubKit
import Foundation
import Testing

struct FinalPullRequestInstructionTests {
    private static let thread = CodeRabbitReviewThread(
        id: "PRRT_1",
        path: "A.swift",
        line: 3,
        isOutdated: false,
        finding: .init(
            id: 2_412_345_678,
            author: "coderabbitai",
            body: "**直して**",
            url: URL(string: "https://github.com/o/r/pull/50#discussion_r2412345678")!,
            createdAt: Date()
        )
    )

    private static func poster(_ http: MockHTTPClient, trusted: [String] = ["mrs1669"]) -> GitHubFinalPullRequestInstructionPoster {
        GitHubFinalPullRequestInstructionPoster(
            client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }),
            trustedAuthors: TrustedAuthors(trusted)
        )
    }

    @Test func buildsInstructionPointingToOneFinding() {
        #expect(FinalPullRequestInstruction.body(for: Self.thread, note: "") == "https://github.com/o/r/pull/50#discussion_r2412345678 を直して")
        #expect(FinalPullRequestInstruction.body(for: Self.thread, note: "  エラーの文言をそろえる\n") == """
            https://github.com/o/r/pull/50#discussion_r2412345678 を直して
            エラーの文言をそろえる
            """)
        // 読む側（FinalPullRequestHistory）が同じ 1 件の指摘を読める（id の直後に日本語が続いても読む）
        let body = FinalPullRequestInstruction.body(for: Self.thread, note: "")
        #expect(body.map(FinalPullRequestHistory.referencedReviewComments(in:)) == [2_412_345_678])
        #expect(FinalPullRequestHistory.referencedReviewComments(in: "#discussion_r2412345678を直して") == [2_412_345_678])
    }

    @Test func rejectsNoteThatPointsToOtherFindingsOrHasMarker() {
        #expect(FinalPullRequestInstruction.body(for: Self.thread, note: "#discussion_r99 も") == nil)
        #expect(FinalPullRequestInstruction.body(for: Self.thread, note: FinalPullRequestMarker.reply) == nil)
        #expect(FinalPullRequestInstruction.body(for: Self.thread, note: FinalPullRequestMarker.orchestrator) == nil)
    }

    @Test func postsInstructionToFinalPullRequestAsTrustedAuthor() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{"data":{"viewer":{"login":"MRS1669"}}}"#),
            .init(status: 201, body: #"{"html_url":"https://github.com/o/r/pull/50#issuecomment-1"}"#)
        ])
        let url = try await Self.poster(http).post(fixing: Self.thread, note: "", to: .fixture())

        #expect(url.absoluteString == "https://github.com/o/r/pull/50#issuecomment-1")
        let request = try #require(http.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/repos/shilokuma-inc/ask-hub-apple/issues/50/comments")
        let sent = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(sent["body"] == "https://github.com/o/r/pull/50#discussion_r2412345678 を直して")
    }

    @Test func refusesToPostAsUntrustedAccount() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{"data":{"viewer":{"login":"someone"}}}"#)])
        await #expect(throws: FinalPullRequestInstructionError.untrustedAccount("someone")) {
            try await Self.poster(http).post(fixing: Self.thread, note: "", to: .fixture())
        }
        #expect(http.requests.count == 1)
    }

    @Test func refusesInvalidInstructionWithoutRequests() async throws {
        let http = MockHTTPClient([])
        await #expect(throws: FinalPullRequestInstructionError.invalidInstruction) {
            try await Self.poster(http).post(fixing: Self.thread, note: "#discussion_r1 も", to: .fixture())
        }
        #expect(http.requests.isEmpty)
    }
}
