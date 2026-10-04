@testable import AskHubKit
import Foundation
import Testing

struct IdeaRequestTests {
    private func makeRequester(_ http: MockHTTPClient) -> GitHubIdeaRequester {
        GitHubIdeaRequester(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    @Test func validatesInput() {
        let valid = IdeaRequest(repository: "shilokuma-inc/notti-ios", summary: " 通知の頻度を調整したい ", body: "朝だけにしたい")
        #expect(valid.isValid)
        #expect(valid.title == "【依頼】通知の頻度を調整したい")

        #expect(!IdeaRequest(repository: "", summary: "要約", body: "本文").isValid)
        for repository in ["o//r", "/o/r", "o/r/", "o", "o/r/x"] {
            #expect(!IdeaRequest(repository: repository, summary: "要約", body: "本文").isValid, "\(repository)")
        }
        #expect(!IdeaRequest(repository: "o/r", summary: "  ", body: "本文").isValid)
        #expect(!IdeaRequest(repository: "o/r", summary: "1 行目\n2 行目", body: "本文").isValid)
        #expect(!IdeaRequest(repository: "o/r", summary: "要約", body: " \n ").isValid)
    }

    @Test func listsUnarchivedRepositoriesByRecentPush() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"""
                [{ "full_name": "shilokuma-inc/ask-hub-apple", "archived": false },
                 { "full_name": "shilokuma-inc/old-app", "archived": true },
                 { "full_name": "shilokuma-inc/notti-ios", "archived": false }]
                """#)
        ])
        let repositories = try await makeRequester(http).repositories(in: "shilokuma-inc")

        #expect(repositories == ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios"])
        let url = try #require(http.requests.first?.url)
        #expect(url.path() == "/orgs/shilokuma-inc/repos")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "sort", value: "pushed")))
        #expect(query.contains(URLQueryItem(name: "type", value: "all")))
    }

    @Test func createsIssueWithIdeaRequestLabel() async throws {
        let http = MockHTTPClient([
            .init(status: 201, body: #"{ "number": 41, "html_url": "https://github.com/shilokuma-inc/notti-ios/issues/41" }"#)
        ])
        let issue = try await makeRequester(http).create(
            IdeaRequest(repository: "shilokuma-inc/notti-ios", summary: "通知の頻度を調整したい", body: "\n朝だけにしたい\n")
        )

        #expect(issue == CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/41")!))
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/repos/shilokuma-inc/notti-ios/issues")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["title"] as? String == "【依頼】通知の頻度を調整したい")
        #expect(body["body"] as? String == "朝だけにしたい")
        #expect(body["labels"] as? [String] == ["idea-request"])
    }

    @Test func rejectsInvalidRequestWithoutSending() async {
        let http = MockHTTPClient([])
        await #expect(throws: IdeaRequestError.invalidRequest) {
            try await makeRequester(http).create(IdeaRequest(repository: "o/r", summary: "", body: "本文"))
        }
        #expect(http.requests.isEmpty)
    }
}
