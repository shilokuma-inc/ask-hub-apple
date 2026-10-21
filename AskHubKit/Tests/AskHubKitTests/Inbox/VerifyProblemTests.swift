@testable import AskHubKit
import Foundation
import Testing

struct VerifyProblemTests {
    private static func issue(kind: InboxIssue.Kind = .needsVerify, body: String = "") -> InboxIssue {
        InboxIssue(
            id: "I_18",
            kind: kind,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 18,
            title: "【CHORE】実機確認: 通知の表示",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            body: body
        )
    }

    @Test func buildsRequestWithMarkerValues() {
        let body = VerifyMarker(pullRequest: 17, epic: "epic/mvp").marker + "\n## 確認手順"
        let problem = VerifyProblem(issue: Self.issue(body: body), description: "\n 通知をタップしても開かない \n")

        #expect(problem.request == IdeaRequest(
            repository: "shilokuma-inc/ask-hub-apple",
            summary: "実機確認の問題: 通知の表示",
            body: """
            実機確認 Issue: https://github.com/shilokuma-inc/ask-hub-apple/issues/18
            元の PR: #17
            epic: epic/mvp

            通知をタップしても開かない
            """
        ))
        #expect(problem.request.title == "【依頼】実機確認の問題: 通知の表示")
        #expect(problem.request.isValid)
    }

    @Test func omitsPullRequestAndEpicWithoutMarker() {
        // 目印の無い Issue の本文の自由文（「元の PR: #41」）からは推測しない
        let problem = VerifyProblem(issue: Self.issue(body: "元の PR: #41"), description: "落ちる")
        #expect(problem.request.body == """
        実機確認 Issue: https://github.com/shilokuma-inc/ask-hub-apple/issues/18

        落ちる
        """)

        let epicOnly = VerifyProblem(issue: Self.issue(body: VerifyMarker(epic: "epic/x").marker), description: "落ちる")
        #expect(epicOnly.request.body.hasPrefix("実機確認 Issue: https://github.com/shilokuma-inc/ask-hub-apple/issues/18\nepic: epic/x\n\n"))
    }

    @Test func commentStartsWithMarkerAndLinksRequest() {
        let problem = VerifyProblem(issue: Self.issue(), description: "  落ちる\n2 回目も  ")
        #expect(problem.comment(request: 41) == """
        <!-- ask-hub:verify-problem -->
        落ちる
        2 回目も

        再修正の依頼: #41
        """)
    }

    @Test func requiresDescriptionAndVerificationIssue() {
        #expect(!VerifyProblem(issue: Self.issue(), description: " \n ").isValid)
        #expect(!VerifyProblem(issue: Self.issue(kind: .decisionLog), description: "落ちる").isValid)
        #expect(VerifyProblem(issue: Self.issue(), description: "落ちる").isValid)
    }
}

struct GitHubVerifyProblemCommenterTests {
    private func makeCommenter(_ http: MockHTTPClient) -> GitHubVerifyProblemCommenter {
        GitHubVerifyProblemCommenter(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private static let request = CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/o/r/issues/41")!)

    private static func problem(kind: InboxIssue.Kind = .needsVerify, description: String = "落ちる") -> VerifyProblem {
        VerifyProblem(
            issue: InboxIssue(
                id: "I_18",
                kind: kind,
                repository: "o/r",
                number: 18,
                title: "【CHORE】実機確認: 通知",
                url: URL(string: "https://github.com/o/r/issues/18")!,
                author: "mrs1669",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            description: description
        )
    }

    @Test func postsCommentToVerificationIssue() async throws {
        let http = MockHTTPClient([
            .init(status: 201, body: #"{ "html_url": "https://github.com/o/r/issues/18#issuecomment-1" }"#)
        ])
        let url = try await makeCommenter(http).post(Self.problem(), request: Self.request)

        #expect(url.absoluteString == "https://github.com/o/r/issues/18#issuecomment-1")
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["POST /repos/o/r/issues/18/comments"])
        let data = try #require(http.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["body": "<!-- ask-hub:verify-problem -->\n落ちる\n\n再修正の依頼: #41"])
    }

    @Test func refusesInvalidProblem() async {
        let http = MockHTTPClient([])
        await #expect(throws: VerifyProblemError.invalidProblem) {
            try await makeCommenter(http).post(Self.problem(description: " "), request: Self.request)
        }
        await #expect(throws: VerifyProblemError.invalidProblem) {
            try await makeCommenter(http).post(Self.problem(kind: .decisionLog), request: Self.request)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func reportsMissingPermission() async {
        let message = "Resource not accessible by personal access token"
        let http = MockHTTPClient([.init(status: 403, body: #"{ "message": "\#(message)" }"#)])
        await #expect(throws: GitHubError.http(status: 403, message: message)) {
            try await makeCommenter(http).post(Self.problem(), request: Self.request)
        }
    }
}
