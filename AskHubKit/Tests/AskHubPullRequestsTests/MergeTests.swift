@testable import AskHubPullRequests
import Foundation
import Testing

struct MergeTests {
    private static let merged = #"{"sha":"\#(Fixture.otherSHA)","merged":true,"message":"Pull Request successfully merged"}"#

    // MARK: - マージ

    @Test func mergesWithMergeCommitPinnedToHead() async throws {
        let transport = StubTransport([.json(200, Self.merged)])
        let result = try await Fixture.client(transport).merge(number: 7, headSHA: Fixture.sha, commitTitle: "題")
        #expect(result == MergedPullRequest(sha: Fixture.otherSHA, mergedNow: true))
        let request = transport.requests.first
        #expect(request?.httpMethod == "PUT")
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/pulls/7/merge")
        let body = Fixture.body(request)
        #expect(body["merge_method"] as? String == "merge")
        #expect(body["sha"] as? String == Fixture.sha)
        #expect(body["commit_title"] as? String == "題")
        #expect(body["commit_message"] == nil)
    }

    @Test func refusesWhenHeadMoved() async throws {
        // 見た後に push された変更をマージしない
        let transport = StubTransport([.json(409, #"{"message":"Head branch was modified. Review and try the merge again."}"#)])
        await #expect(throws: PullRequestError.headChanged) {
            try await Fixture.client(transport).merge(number: 7, headSHA: Fixture.sha)
        }
    }

    @Test func treatsPreviousMergeOfSameHeadAsDone() async throws {
        // 前の試行がマージした後、記録する前に落ちた
        let pull = Fixture.pull(7, extra: ["state": "closed", "merged": true, "merge_commit_sha": Fixture.otherSHA])
        let transport = StubTransport([.json(405, #"{"message":"Pull Request is not mergeable"}"#), .json(200, Fixture.json(pull))])
        let result = try await Fixture.client(transport).merge(number: 7, headSHA: Fixture.sha)
        #expect(result == MergedPullRequest(sha: Fixture.otherSHA, mergedNow: false))
        #expect(transport.requests.map(\.httpMethod) == ["PUT", "GET"])
    }

    @Test func reportsNotMergeable() async throws {
        let transport = StubTransport([
            .json(405, #"{"message":"Pull Request is not mergeable"}"#),
            .json(200, Fixture.json(Fixture.pull(7, extra: ["merged": false, "mergeable": false, "mergeable_state": "dirty"])))
        ])
        await #expect(throws: PullRequestError.notMergeable(message: "Pull Request is not mergeable")) {
            try await Fixture.client(transport).merge(number: 7, headSHA: Fixture.sha)
        }
    }

    @Test func doesNotTreatMergeOfAnotherHeadAsDone() async throws {
        // マージされていても、見た head と違うものなら、こちらがマージしたものではない
        let pull = Fixture.pull(7, sha: Fixture.otherSHA, extra: ["state": "closed", "merged": true])
        let transport = StubTransport([.json(405, #"{"message":"Pull Request is not mergeable"}"#), .json(200, Fixture.json(pull))])
        await #expect(throws: PullRequestError.notMergeable(message: "Pull Request is not mergeable")) {
            try await Fixture.client(transport).merge(number: 7, headSHA: Fixture.sha)
        }
    }

    @Test func refusesArgumentsOfWrongShapeWithoutSending() async throws {
        let transport = StubTransport([])
        let client = Fixture.client(transport)
        await #expect(throws: PullRequestError.invalidArgument("SHA の形が違う")) {
            try await client.merge(number: 7, headSHA: "HEAD")
        }
        await #expect(throws: PullRequestError.invalidArgument("番号が 1 より小さい")) {
            try await client.merge(number: 0, headSHA: Fixture.sha)
        }
        #expect(transport.requests.isEmpty)
    }

    // MARK: - ブランチの削除

    private static func ref(_ sha: String) -> String {
        #"{"ref":"refs/heads/feat/task-1","object":{"sha":"\#(sha)","type":"commit"}}"#
    }

    @Test func deletesBranchAtMergedHead() async throws {
        let transport = StubTransport([.json(200, Self.ref(Fixture.sha)), .init(status: 204)])
        let result = try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha)
        #expect(result == .deleted)
        #expect(transport.requests.map(\.httpMethod) == ["GET", "DELETE"])
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/git/ref/heads/feat/task-1")
        #expect(Fixture.path(transport.requests.last) == "/repos/shilokuma-inc/ask-hub-apple/git/refs/heads/feat/task-1")
    }

    @Test func keepsBranchPushedAfterMerge() async throws {
        let transport = StubTransport([.json(200, Self.ref(Fixture.otherSHA))])
        await #expect(throws: PullRequestError.headChanged) {
            try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func treatsMissingBranchAsAlreadyGone() async throws {
        let transport = StubTransport([.json(404, #"{"message":"Not Found"}"#)])
        #expect(try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha) == .alreadyGone)
        #expect(transport.requests.count == 1)
    }

    /// 読んだ後に消えた（マージで GitHub が自動で消したなど）。GitHub は削除を 422 か 404 で断る
    @Test(arguments: [
        StubTransport.Reply.json(422, #"{"message":"Reference does not exist"}"#),
        StubTransport.Reply.json(404, #"{"message":"Not Found"}"#)
    ])
    func treatsBranchDeletedMeanwhileAsAlreadyGone(_ refusal: StubTransport.Reply) async throws {
        let transport = StubTransport([.json(200, Self.ref(Fixture.sha)), refusal, .json(404, #"{"message":"Not Found"}"#)])
        #expect(try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha) == .alreadyGone)
        #expect(transport.requests.count == 3)
    }

    @Test func reportsOtherRejectionOfDeletion() async throws {
        let transport = StubTransport([
            .json(200, Self.ref(Fixture.sha)),
            .json(422, #"{"message":"Cannot delete this protected branch"}"#),
            .json(200, Self.ref(Fixture.sha))
        ])
        await #expect(throws: PullRequestError.rejected(message: "Cannot delete this protected branch")) {
            try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha)
        }
    }

    @Test func reportsNotFoundWhenBranchStillExists() async throws {
        // 権限が無いときも GitHub は 404 を返す。ブランチが残っていれば消えたことにしない
        let transport = StubTransport([
            .json(200, Self.ref(Fixture.sha)),
            .json(404, #"{"message":"Not Found"}"#),
            .json(200, Self.ref(Fixture.sha))
        ])
        await #expect(throws: PullRequestError.notFound) {
            try await Fixture.client(transport).deleteBranch("feat/task-1", expectedSHA: Fixture.sha)
        }
    }

    // MARK: - 流し直し

    @Test func rerunsFailedJobs() async throws {
        let transport = StubTransport([.json(201, "{}")])
        try await Fixture.client(transport).rerunFailedJobs(runID: 111)
        #expect(transport.requests.first?.httpMethod == "POST")
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs/111/rerun-failed-jobs")
    }

    @Test func reportsForbiddenRerun() async throws {
        // トークンに Actions の書き込みの権限が無い
        let transport = StubTransport([.json(403, #"{"message":"Resource not accessible by personal access token"}"#)])
        await #expect(throws: PullRequestError.forbidden(message: "Resource not accessible by personal access token")) {
            try await Fixture.client(transport).rerunFailedJobs(runID: 111)
        }
    }
}
