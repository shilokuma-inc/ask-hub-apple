@testable import AskHubPullRequests
import Foundation
import Testing

struct OpenPullRequestTests {
    private let draft = PullRequestDraft(base: "epic/feature", head: "feat/task-1", title: "【FEAT】タスク 1", body: "本文")

    @Test func createsWhenNoneIsOpen() async throws {
        let transport = StubTransport([.json(200, "[]"), .json(201, Fixture.json(Fixture.pull(7)))])
        let opened = try await Fixture.client(transport).openPullRequest(draft)
        #expect(opened.created)
        #expect(opened.pullRequest.number == 7)
        #expect(opened.pullRequest.headSHA == Fixture.sha)
        #expect(opened.pullRequest.url?.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/pull/7")

        let list = transport.requests.first
        #expect(list?.httpMethod == "GET")
        #expect(Fixture.path(list) == "/repos/shilokuma-inc/ask-hub-apple/pulls")
        #expect(Fixture.query(list) == ["state": "open", "head": "shilokuma-inc:feat/task-1", "base": "epic/feature", "per_page": "100"])
        #expect(list?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.token)")
        #expect(list?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(list?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")

        let create = transport.requests.last
        #expect(create?.httpMethod == "POST")
        #expect(Fixture.path(create) == "/repos/shilokuma-inc/ask-hub-apple/pulls")
        let body = Fixture.body(create)
        #expect(body["title"] as? String == "【FEAT】タスク 1")
        #expect(body["head"] as? String == "feat/task-1")
        #expect(body["base"] as? String == "epic/feature")
        #expect(body["body"] as? String == "本文")
    }

    @Test func returnsOpenPullRequestWithoutCreatingAnother() async throws {
        // 前の試行が作った後、記録する前に落ちた
        let transport = StubTransport([.json(200, Fixture.json([Fixture.pull(5)]))])
        let opened = try await Fixture.client(transport).openPullRequest(draft)
        #expect(!opened.created)
        #expect(opened.pullRequest.number == 5)
        #expect(transport.requests.count == 1)
    }

    @Test func ignoresSameBranchOfAnotherRepository() async throws {
        // `head` の絞り込みは持ち主とブランチ名だけなので、同じ持ち主のフォークの PR も返りうる
        let fork = Fixture.pull(3, headRepo: "shilokuma-inc/ask-hub-apple-fork")
        let transport = StubTransport([.json(200, Fixture.json([fork])), .json(201, Fixture.json(Fixture.pull(8)))])
        let opened = try await Fixture.client(transport).openPullRequest(draft)
        #expect(opened.created)
        #expect(opened.pullRequest.number == 8)
    }

    @Test func followsPagesToFindOpenPullRequest() async throws {
        let next = "https://api.github.com/repositories/1/pulls?state=open&page=2"
        let transport = StubTransport([
            .json(200, Fixture.json([Fixture.pull(2, head: "feat/other")]), headers: Fixture.link(next: next)),
            .json(200, Fixture.json([Fixture.pull(4)]))
        ])
        let opened = try await Fixture.client(transport).openPullRequest(draft)
        #expect(!opened.created)
        #expect(opened.pullRequest.number == 4)
        #expect(transport.requests.map { $0.url?.absoluteString }.last == next)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.token)")
    }

    @Test func returnsPullRequestCreatedByAnotherAttemptMeanwhile() async throws {
        let message = "A pull request already exists for shilokuma-inc:feat/task-1."
        let exists = Fixture.json(["message": "Validation Failed", "errors": [["message": message]]])
        let transport = StubTransport([.json(200, "[]"), .json(422, exists), .json(200, Fixture.json([Fixture.pull(9)]))])
        let opened = try await Fixture.client(transport).openPullRequest(draft)
        #expect(!opened.created)
        #expect(opened.pullRequest.number == 9)
        #expect(transport.requests.map(\.httpMethod) == ["GET", "POST", "GET"])
    }

    @Test func rethrowsRejectionWhenNothingIsOpen() async throws {
        let invalid = #"{"message":"Validation Failed","errors":[{"message":"No commits between epic/feature and feat/task-1"}]}"#
        let transport = StubTransport([.json(200, "[]"), .json(422, invalid), .json(200, "[]")])
        await #expect(throws: PullRequestError.rejected(message: "Validation Failed: No commits between epic/feature and feat/task-1")) {
            try await Fixture.client(transport).openPullRequest(draft)
        }
    }

    @Test func listsOpenPullRequestsFromHeadToAnyBase() async throws {
        let next = "https://api.github.com/repositories/1/pulls?state=open&page=2"
        let transport = StubTransport([
            .json(200, Fixture.json([Fixture.pull(2, head: "feat/other"), Fixture.pull(3)]), headers: Fixture.link(next: next)),
            .json(200, Fixture.json([
                Fixture.pull(4, base: "develop"),
                Fixture.pull(6, headRepo: "shilokuma-inc/ask-hub-apple-fork")
            ]))
        ])
        let pulls = try await Fixture.client(transport).openPullRequests(head: "feat/task-1")
        // 向き先は問わず、ほかのブランチとフォークの PR は除く
        #expect(pulls.map(\.number) == [3, 4])
        #expect(pulls.map(\.baseRef) == ["epic/feature", "develop"])
        let list = transport.requests.first
        #expect(Fixture.path(list) == "/repos/shilokuma-inc/ask-hub-apple/pulls")
        #expect(Fixture.query(list) == ["state": "open", "head": "shilokuma-inc:feat/task-1", "per_page": "100"])
        #expect(transport.requests.map { $0.url?.absoluteString }.last == next)
    }

    @Test func readsBranchHead() async throws {
        let ref = #"{"ref":"refs/heads/feat/task-1","object":{"sha":"\#(Fixture.sha)","type":"commit"}}"#
        let transport = StubTransport([.json(200, ref), .json(404, #"{"message":"Not Found"}"#)])
        let client = Fixture.client(transport)
        #expect(try await client.branchHead("feat/task-1") == Fixture.sha)
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/git/ref/heads/feat/task-1")
        // 無ければ nil
        #expect(try await client.branchHead("feat/task-1") == nil)
    }

    @Test(arguments: ["../main", "-x", "a//b", "a b", "a?b", "", "x.lock", "/a", "a/"])
    func refusesBranchNamesOfWrongShapeWithoutSending(_ head: String) async throws {
        let transport = StubTransport([])
        var draft = draft
        draft.head = head
        await #expect(throws: PullRequestError.invalidArgument("ブランチ名の形が違う")) {
            try await Fixture.client(transport).openPullRequest(draft)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func readsPullRequest() async throws {
        let computing = Fixture.pull(7, extra: ["merged": false, "mergeable": NSNull(), "mergeable_state": "unknown"])
        let merged = Fixture.pull(7, extra: [
            "state": "closed", "merged": true, "mergeable": NSNull(), "merge_commit_sha": Fixture.otherSHA,
            "merged_at": "2026-11-07T01:00:00Z"
        ])
        let clean = Fixture.pull(7, extra: ["merged": false, "mergeable": true, "mergeable_state": "clean"])
        let transport = StubTransport([computing, merged, clean].map { .json(200, Fixture.json($0)) })
        let client = Fixture.client(transport)

        let first = try await client.pullRequest(number: 7)
        #expect(first.state == .open)
        #expect(!first.merged)
        #expect(first.mergeable == nil)
        #expect(first.mergeableState == "unknown")
        #expect(first.headRef == "feat/task-1")
        #expect(first.baseRef == "epic/feature")
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/pulls/7")

        let second = try await client.pullRequest(number: 7)
        #expect(second.state == .closed)
        #expect(second.merged)
        #expect(second.mergeCommitSHA == Fixture.otherSHA)

        let third = try await client.pullRequest(number: 7)
        #expect(third.mergeable == true)
        #expect(third.mergeableState == "clean")
    }

    @Test func treatsMergedAtAsMergedInList() async throws {
        let merged = Fixture.pull(5, extra: ["merged_at": "2026-11-07T01:00:00Z"])
        let transport = StubTransport([.json(200, Fixture.json([merged]))])
        let found = try await Fixture.client(transport).openPullRequest(head: "feat/task-1", base: "epic/feature")
        #expect(found?.merged == true)
        #expect(found?.mergeable == nil)
    }
}
