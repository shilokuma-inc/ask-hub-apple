import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct GitHubOrchestratorTests {
    /// 登録した順に 200 のレスポンスを返し、送られたリクエストを記録する
    final class StubHTTPClient: HTTPClient {
        private let state: OSAllocatedUnfairLock<(responses: [(status: Int, body: String)], requests: [URLRequest])>

        /// すべて 200 で返す
        convenience init(_ bodies: [String]) {
            self.init(responses: bodies.map { (200, $0) })
        }

        init(responses: [(status: Int, body: String)]) {
            state = OSAllocatedUnfairLock(initialState: (responses, []))
        }

        var requests: [URLRequest] {
            state.withLock { $0.requests }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let next = try state.withLock { state in
                state.requests.append(request)
                guard !state.responses.isEmpty else {
                    throw GitHubError.invalidResponse
                }
                return state.responses.removeFirst()
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: nil) else {
                throw GitHubError.invalidResponse
            }
            return (Data(next.body.utf8), response)
        }
    }

    func makeGitHub(_ http: StubHTTPClient) -> GitHubOrchestrator {
        GitHubOrchestrator(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    func requestJSON(_ request: URLRequest) throws -> (query: String, variables: [String: Any]) {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (try #require(object["query"] as? String), try #require(object["variables"] as? [String: Any]))
    }

    private static let readyLabel = #"{ "id": "LA_1", "name": "ready-for-loop" }"#

    private static func discussion(id: String, number: Int, closed: Bool = false, labels: String = readyLabel) -> String {
        #"""
        { "id": "\#(id)", "number": \#(number), "title": "T\#(number)", "url": "https://github.com/o/r/discussions/\#(number)",
          "closed": \#(closed), "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" },
          "labels": { "nodes": [\#(labels)] } }
        """#
    }

    private static let otherAndCapitalizedReadyLabels = #"{ "id": "LA_X", "name": "bug" }, { "id": "LA_9", "name": "Ready-For-Loop" }"#

    @Test func searchesReadyDiscussionsAcrossPagesAndSkipsUnusableNodes() async throws {
        let http = StubHTTPClient([
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": true, "endCursor": "S1" }, "nodes": [
              \#(Self.discussion(id: "D_1", number: 1)),
              {},
              \#(Self.discussion(id: "D_2", number: 2, closed: true))
            ] } } }
            """#,
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
              \#(Self.discussion(id: "D_3", number: 3, labels: Self.otherAndCapitalizedReadyLabels)),
              \#(Self.discussion(id: "D_4", number: 4, labels: "")),
              null
            ] } } }
            """#
        ])
        let discussions = try await makeGitHub(http).readyForLoopDiscussions(orgs: ["shilokuma-inc"])

        #expect(discussions.map(\.nodeID) == ["D_1", "D_3"])
        #expect(discussions.map(\.readyLabelID) == ["LA_1", "LA_9"])
        #expect(discussions.first?.author == "mrs1669")
        #expect(discussions.first?.repository == "o/r")
        let first = try requestJSON(http.requests[0])
        #expect(first.variables["query"] as? String == "org:shilokuma-inc label:ready-for-loop is:open")
        #expect(first.variables["after"] is NSNull)
        #expect(try requestJSON(http.requests[1]).variables["after"] as? String == "S1")
    }

    @Test func removesReadyLabelByNodeIDs() async throws {
        let http = StubHTTPClient([#"{ "data": { "removeLabelsFromLabelable": { "clientMutationId": null } } }"#])
        try await makeGitHub(http).removeReadyLabel(from: .fixture(number: 5))

        let request = try requestJSON(http.requests[0])
        #expect(request.query.contains("removeLabelsFromLabelable"))
        #expect(request.variables["labelable"] as? String == "D_5")
        #expect(request.variables["labels"] as? [String] == ["LA_ready"])
    }

    @Test func removesNeedsAnswerByLookingUpLabelID() async throws {
        let http = StubHTTPClient([
            #"{ "data": { "repository": { "label": { "id": "LA_needs" } } } }"#,
            #"{ "data": { "removeLabelsFromLabelable": { "clientMutationId": null } } }"#
        ])
        let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_7",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 7,
            title: "T",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/7")!
        )
        try await makeGitHub(http).removeNeedsAnswerLabel(from: subject)

        let lookup = try requestJSON(http.requests[0])
        #expect(lookup.variables["owner"] as? String == "shilokuma-inc")
        #expect(lookup.variables["name"] as? String == "ask-hub-apple")
        #expect(lookup.variables["label"] as? String == "needs-answer")
        let mutation = try requestJSON(http.requests[1])
        #expect(mutation.variables["labelable"] as? String == "D_7")
        #expect(mutation.variables["labels"] as? [String] == ["LA_needs"])
    }

    @Test func skipsMutationWhenRepositoryHasNoNeedsAnswerLabel() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": { "label": null } } }"#])
        let subject = InboxSubject(
            kind: .pullRequest,
            nodeID: "PR_1",
            repository: "o/r",
            number: 1,
            title: "T",
            url: URL(string: "https://github.com/o/r/pull/1")!
        )
        try await makeGitHub(http).removeNeedsAnswerLabel(from: subject)
        #expect(http.requests.count == 1)
    }

    @Test func addsReadyForLoopByLookingUpLabelID() async throws {
        let http = StubHTTPClient([
            #"{ "data": { "repository": { "label": { "id": "LA_ready" } } } }"#,
            #"{ "data": { "addLabelsToLabelable": { "clientMutationId": null } } }"#
        ])
        let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_115",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 115,
            title: "T",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/115")!
        )
        try await makeGitHub(http).addReadyLabel(to: subject)

        let lookup = try requestJSON(http.requests[0])
        #expect(lookup.variables["label"] as? String == "ready-for-loop")
        let mutation = try requestJSON(http.requests[1])
        #expect(mutation.query.contains("addLabelsToLabelable"))
        #expect(mutation.variables["labelable"] as? String == "D_115")
        #expect(mutation.variables["labels"] as? [String] == ["LA_ready"])
    }

    @Test func failsToAddReadyForLoopWhenMutationPayloadIsNull() async throws {
        let http = StubHTTPClient([
            #"{ "data": { "repository": { "label": { "id": "LA_ready" } } } }"#,
            #"{ "data": { "addLabelsToLabelable": null } }"#
        ])
        let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_1",
            repository: "o/r",
            number: 1,
            title: "T",
            url: URL(string: "https://github.com/o/r/discussions/1")!
        )
        await #expect(throws: (any Error).self) { try await self.makeGitHub(http).addReadyLabel(to: subject) }
    }

    @Test func failsToAddReadyForLoopWhenRepositoryHasNoLabel() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": { "label": null } } }"#])
        let subject = InboxSubject(
            kind: .discussion,
            nodeID: "D_1",
            repository: "o/r",
            number: 1,
            title: "T",
            url: URL(string: "https://github.com/o/r/discussions/1")!
        )
        // ラベルが無いと付けられないので失敗として返す（呼び出し側は needs-answer を残して再試行する）
        await #expect(throws: (any Error).self) { try await self.makeGitHub(http).addReadyLabel(to: subject) }
        #expect(http.requests.count == 1)
    }

    @Test func updatesPullRequestBodyWithPatch() async throws {
        let http = StubHTTPClient([#"{ "number": 9, "state": "open", "body": "新しい本文" }"#])
        try await makeGitHub(http).updatePullRequestBody(in: "shilokuma-inc/ask-hub-apple", number: 9, body: "新しい本文")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/repos/shilokuma-inc/ask-hub-apple/pulls/9")
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["body": "新しい本文"])
    }

    @Test func findsPullRequestsToDefaultBranchByHeadPreferringOpen() async throws {
        let repositoryInfo = #"{ "default_branch": "develop" }"#
        let http = StubHTTPClient([
            repositoryInfo, "[]",
            repositoryInfo, #"[{ "number": 7, "state": "closed" }]"#,
            repositoryInfo, #"[{ "number": 7, "state": "closed" }, { "number": 9, "state": "open" }]"#
        ])
        let github = makeGitHub(http)
        let repository = "shilokuma-inc/ask-hub-apple"
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == nil)
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == ExistingPullRequest(number: 7, isOpen: false))
        #expect(try await github.existingPullRequest(in: repository, head: "epic/mvp") == ExistingPullRequest(number: 9, isOpen: true))

        #expect(http.requests[0].url?.path() == "/repos/shilokuma-inc/ask-hub-apple")
        let url = try #require(http.requests[1].url)
        #expect(url.path() == "/repos/shilokuma-inc/ask-hub-apple/pulls")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "head", value: "shilokuma-inc:epic/mvp")))
        #expect(query.contains(URLQueryItem(name: "base", value: "develop")))
        #expect(query.contains(URLQueryItem(name: "state", value: "all")))
    }

    @Test func createsEpicFinalPullRequestToDefaultBranchWithLabel() async throws {
        let http = StubHTTPClient([
            #"{ "default_branch": "develop" }"#,
            #"{ "number": 42, "state": "open" }"#,
            #"[{ "name": "epic-final" }]"#
        ])
        let github = makeGitHub(http)
        let number = try await github.createEpicFinalPullRequest(in: "o/r", head: "epic/mvp", body: "まとめ")
        #expect(number == 42)
        try await github.addEpicFinalLabel(in: "o/r", number: number)

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /repos/o/r",
            "POST /repos/o/r/pulls",
            "POST /repos/o/r/issues/42/labels"
        ])
        let pullBody = try #require(http.requests[1].httpBody)
        let pull = try #require(try JSONSerialization.jsonObject(with: pullBody) as? [String: String])
        #expect(pull["title"] == "【FEAT】epic/mvp を develop に取り込む")
        #expect(pull["head"] == "epic/mvp")
        #expect(pull["base"] == "develop")
        #expect(pull["body"]?.hasPrefix("まとめ\n\n---\n") == true)
        let labelsBody = try #require(http.requests[2].httpBody)
        let labels = try #require(try JSONSerialization.jsonObject(with: labelsBody) as? [String: [String]])
        #expect(labels == ["labels": ["epic-final"]])
    }

    @Test func searchesOpenIdeaRequestsInOrg() async throws {
        let http = StubHTTPClient([
            #"""
            { "data": { "search": { "pageInfo": { "hasNextPage": false, "endCursor": null }, "nodes": [
              { "id": "I_7", "number": 7, "title": "【依頼】通知", "body": "朝だけ", "url": "https://github.com/o/r/issues/7",
                "author": { "login": "mrs1669" }, "repository": { "nameWithOwner": "o/r" } },
              {}
            ] } } }
            """#
        ])
        let issues = try await makeGitHub(http).ideaRequests(orgs: ["shilokuma-inc"])

        #expect(issues.map(\.number) == [7])
        #expect(issues.first?.body == "朝だけ")
        #expect(issues.first?.author == "mrs1669")
        #expect(try requestJSON(http.requests[0]).variables["query"] as? String == "org:shilokuma-inc is:issue is:open label:idea-request")
    }

    @Test func commentsAndClosesIdeaRequest() async throws {
        let http = StubHTTPClient([#"{ "id": 1 }"#, #"{ "number": 7, "state": "closed" }"#])
        let github = makeGitHub(http)
        let issue = IdeaRequestIssue.fixture(repository: "o/r", number: 7)
        try await github.comment(on: issue, body: "作りました")
        try await github.close(issue)

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /repos/o/r/issues/7/comments",
            "PATCH /repos/o/r/issues/7"
        ])
        let closeBody = try #require(http.requests[1].httpBody)
        let close = try #require(try JSONSerialization.jsonObject(with: closeBody) as? [String: String])
        #expect(close == ["state": "closed", "state_reason": "completed"])
    }

    @Test func updatesHeartbeatLabelOrCreatesIt() async throws {
        let http = StubHTTPClient([#"{ "name": "askhub-orchestrator" }"#])
        try await makeGitHub(http).updateHeartbeat(in: "o/r", description: "最終確認")
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["PATCH /repos/o/r/labels/askhub-orchestrator"])
        let patchBody = try #require(http.requests[0].httpBody)
        #expect(try JSONSerialization.jsonObject(with: patchBody) as? [String: String] == ["description": "最終確認"])

        // ラベルが無ければ作る
        let missing = StubHTTPClient(responses: [(404, #"{ "message": "Not Found" }"#), (201, #"{ "name": "askhub-orchestrator" }"#)])
        try await makeGitHub(missing).updateHeartbeat(in: "o/r", description: "最終確認")
        #expect(missing.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "PATCH /repos/o/r/labels/askhub-orchestrator",
            "POST /repos/o/r/labels"
        ])
        let createBody = try #require(missing.requests[1].httpBody)
        let created = try #require(try JSONSerialization.jsonObject(with: createBody) as? [String: String])
        #expect(created["name"] == "askhub-orchestrator")
        #expect(created["description"] == "最終確認")
    }

    @Test func removeLabelReportsGraphQLErrors() async {
        let http = StubHTTPClient([#"{ "data": null, "errors": [{ "message": "Resource not accessible" }] }"#])
        await #expect(throws: GitHubError.graphQL(messages: ["Resource not accessible"])) {
            try await makeGitHub(http).removeReadyLabel(from: .fixture())
        }
    }
}

// MARK: - 仮決め一覧（decision-log）

extension GitHubOrchestratorTests {
    @Test func prefersMergedPullRequestAmongClosedOnes() async throws {
        let http = StubHTTPClient([
            #"{ "default_branch": "develop" }"#,
            #"""
            [{ "number": 7, "state": "closed", "merged_at": null },
             { "number": 8, "state": "closed", "merged_at": "2026-10-04T21:13:30Z" }]
            """#
        ])
        let pull = try await makeGitHub(http).existingPullRequest(in: "o/r", head: "epic/mvp")
        #expect(pull == ExistingPullRequest(number: 8, isOpen: false, isMerged: true))
    }

    @Test func fetchesOpenDecisionLogsWithoutPullRequests() async throws {
        let http = StubHTTPClient([
            #"""
            [{ "number": 9, "title": "【CHORE】epic/mvp の仮決め一覧", "body": "- [ ] #3 色" },
             { "number": 10, "title": "PR", "body": null, "pull_request": { "url": "https://api.github.com/repos/o/r/pulls/10" } }]
            """#
        ])
        let issues = try await makeGitHub(http).decisionLogs(in: "o/r")

        #expect(issues == [DecisionLogIssue(repository: "o/r", number: 9, title: "【CHORE】epic/mvp の仮決め一覧", body: "- [ ] #3 色")])
        let url = try #require(http.requests.first?.url)
        #expect(url.path() == "/repos/o/r/issues")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "labels", value: "decision-log")))
        #expect(query.contains(URLQueryItem(name: "state", value: "open")))
    }

    @Test func commentsOnAndClosesDecisionLog() async throws {
        let http = StubHTTPClient([
            ##"[{ "id": 1, "user": { "login": "mrs1669" }, "body": "#3 は別案 1 で" }, { "id": 2, "user": null, "body": null }]"##,
            #"{ "id": 3 }"#,
            #"{ "number": 9, "state": "closed" }"#
        ])
        let github = makeGitHub(http)
        let issue = DecisionLogIssue(repository: "o/r", number: 9, title: "T", body: "")

        #expect(try await github.comments(in: "o/r", issue: 9) == [
            IssueComment(id: 1, author: "mrs1669", body: "#3 は別案 1 で"),
            IssueComment(id: 2, author: nil, body: "")
        ])
        try await github.comment(on: issue, body: "閉じます")
        try await github.close(issue)

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /repos/o/r/issues/9/comments",
            "POST /repos/o/r/issues/9/comments",
            "PATCH /repos/o/r/issues/9"
        ])
        let body = try #require(http.requests.last?.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object == ["state": "closed", "state_reason": "completed"])
    }
}

// MARK: - 状態用の Issue（loop-status）

extension GitHubOrchestratorTests {
    @Test func listsLoopStatusIssuesIncludingClosedOnes() async throws {
        let http = StubHTTPClient([
            #"""
            [{ "number": 3, "state": "open", "body": "本文", "user": { "login": "mrs1669" }, "updated_at": "2027-01-15T08:00:00Z" },
             { "number": 4, "state": "closed", "body": null, "user": null, "updated_at": "2027-01-15T07:00:00Z" },
             { "number": 5, "state": "open", "body": "", "user": { "login": "mrs1669" }, "updated_at": "2027-01-15T08:00:00Z",
               "pull_request": { "url": "https://api.github.com/repos/o/r/pulls/5" } }]
            """#
        ])
        let issues = try await makeGitHub(http).loopStatusIssues(in: "o/r")

        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(issues == [
            LoopStatusIssueRecord(number: 3, author: "mrs1669", isOpen: true, updatedAt: updatedAt, body: "本文"),
            LoopStatusIssueRecord(number: 4, author: nil, isOpen: false, updatedAt: updatedAt.addingTimeInterval(-3600), body: "")
        ])
        let url = try #require(http.requests.first?.url)
        #expect(url.path() == "/repos/o/r/issues")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "labels", value: "loop-status")))
        #expect(query.contains(URLQueryItem(name: "state", value: "all")))
    }

    @Test func createsLoopStatusIssueWithLabelAndReopensOnUpdate() async throws {
        let http = StubHTTPClient(responses: [
            // ラベルが既にあれば 422
            (422, #"{ "message": "Validation Failed" }"#),
            (201, #"{ "number": 11 }"#),
            (200, #"{ "number": 11 }"#)
        ])
        let github = makeGitHub(http)
        #expect(try await github.createLoopStatusIssue(in: "o/r", body: "状態") == 11)
        try await github.updateLoopStatusIssue(in: "o/r", number: 11, body: "新しい状態")

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /repos/o/r/labels",
            "POST /repos/o/r/issues",
            "PATCH /repos/o/r/issues/11"
        ])
        let createBody = try #require(http.requests[1].httpBody)
        let created = try #require(try JSONSerialization.jsonObject(with: createBody) as? [String: Any])
        #expect(created["title"] as? String == "【AskHub】ループの状態")
        #expect(created["labels"] as? [String] == ["loop-status"])
        let updateBody = try #require(http.requests[2].httpBody)
        let updated = try #require(try JSONSerialization.jsonObject(with: updateBody) as? [String: String])
        #expect(updated == ["body": "新しい状態", "state": "open"])
    }
}
