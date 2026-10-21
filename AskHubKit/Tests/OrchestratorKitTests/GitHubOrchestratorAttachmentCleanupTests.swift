import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR のマージ後の添付の片付け（Discussion #669 の Q7）

extension GitHubOrchestratorTests {
    private static let head = String(repeating: "1", count: 40)
    private static let treeSHA = String(repeating: "2", count: 40)
    private static let keep = "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/keep.png"
    private static let gone = "files/6ba7b810-9dad-11d1-80b4-00c04fd430c8/gone.png"

    private static func requestLine(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "") \(request.url?.path() ?? "")"
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func treeResponse(_ paths: [String], truncated: Bool = false) -> String {
        let entries = (paths + ["README.md"]).map { #"{ "path": "\#($0)", "type": "blob" }"# }.joined(separator: ",")
        return #"{ "tree": [\#(entries), { "path": "files", "type": "tree" }], "truncated": \#(truncated) }"#
    }

    private static let refResponse = #"{ "object": { "sha": "\#(head)" } }"#
    private static let commitResponse = #"{ "tree": { "sha": "\#(treeSHA)" } }"#

    @Test func listsOnlyMergedEpicFinalPullRequests() async throws {
        let body = #"""
        [
          { "number": 30, "body": "<!-- ask-hub:discussion 12 -->\n本文", "head": { "ref": "epic/mvp" }, "user": { "login": "mrs1669" },
            "labels": [{ "name": "epic-final" }], "merged_at": "2026-10-21T00:00:00Z" },
          { "number": 31, "body": null, "head": { "ref": "epic/closed" }, "user": { "login": "mrs1669" },
            "labels": [{ "name": "epic-final" }], "merged_at": null },
          { "number": 32, "body": null, "head": { "ref": "feat/x" }, "user": { "login": "mrs1669" },
            "labels": [], "merged_at": "2026-10-21T00:00:00Z" }
        ]
        """#
        let http = StubHTTPClient([body])
        let pulls = try await makeGitHub(http).mergedEpicFinalPullRequests(in: "o/r")

        let expected = MergedEpicFinalPullRequest(
            repository: "o/r", number: 30, headBranch: "epic/mvp", author: "mrs1669", goalDiscussion: 12
        )
        #expect(pulls == [expected])
        let url = try #require(http.requests.first?.url)
        #expect(url.path() == "/repos/o/r/pulls")
        #expect(url.query()?.contains("state=closed") == true)
        #expect(url.query()?.contains("sort=updated") == true)
    }

    @Test func deletesOnlyExistingPathsInOneCommit() async throws {
        let http = StubHTTPClient([
            Self.refResponse,
            Self.commitResponse,
            Self.treeResponse([Self.keep, Self.gone]),
            #"{ "sha": "\#(String(repeating: "3", count: 40))" }"#,
            #"{ "sha": "\#(String(repeating: "4", count: 40))" }"#,
            #"{ "ref": "refs/heads/askhub/attachments" }"#
        ])
        let missing = "files/6ba7b811-9dad-11d1-80b4-00c04fd430c8/missing.png"
        let deleted = try await makeGitHub(http).deleteAttachments(at: [Self.gone, missing], in: "o/r")

        #expect(deleted == 1)
        #expect(http.requests.map(Self.requestLine) == [
            "GET /repos/o/r/git/ref/heads/askhub/attachments",
            "GET /repos/o/r/git/commits/\(Self.head)",
            "GET /repos/o/r/git/trees/\(Self.treeSHA)",
            "POST /repos/o/r/git/trees",
            "POST /repos/o/r/git/commits",
            "PATCH /repos/o/r/git/refs/heads/askhub/attachments"
        ])
        let tree = try Self.jsonBody(http.requests[3])
        #expect(tree["base_tree"] as? String == Self.treeSHA)
        let entries = try #require(tree["tree"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["path"] as? String == Self.gone)
        // sha を null にすると、そのパスを消す（README.md やほかのパスは base_tree のまま残る）
        #expect(entries.first?["sha"] is NSNull)
        let commit = try Self.jsonBody(http.requests[4])
        #expect(commit["parents"] as? [String] == [Self.head])
        let ref = try Self.jsonBody(http.requests[5])
        #expect(ref["sha"] as? String == String(repeating: "4", count: 40))
        #expect(ref["force"] as? Bool == false)
    }

    @Test func returnsZeroWithoutBranchOrPaths() async throws {
        let noBranch = StubHTTPClient(responses: [(404, #"{ "message": "Not Found" }"#)])
        #expect(try await makeGitHub(noBranch).deleteAttachments(at: [Self.gone], in: "o/r") == 0)
        #expect(noBranch.requests.count == 1)

        let noPaths = StubHTTPClient([Self.refResponse, Self.commitResponse, Self.treeResponse([Self.keep])])
        #expect(try await makeGitHub(noPaths).deleteAttachments(at: [Self.gone], in: "o/r") == 0)
        // 消すものが無ければ tree もコミットも作らない
        #expect(noPaths.requests.count == 3)
    }

    @Test func triesAllPathsWhenTreeIsTruncated() async throws {
        let http = StubHTTPClient([
            Self.refResponse,
            Self.commitResponse,
            Self.treeResponse([], truncated: true),
            #"{ "sha": "\#(String(repeating: "3", count: 40))" }"#,
            #"{ "sha": "\#(String(repeating: "4", count: 40))" }"#,
            #"{ "ref": "refs/heads/askhub/attachments" }"#
        ])
        #expect(try await makeGitHub(http).deleteAttachments(at: [Self.gone], in: "o/r") == 1)
    }

    @Test func reportsConflictWhenRefUpdateIsRejected() async throws {
        let http = StubHTTPClient(responses: [
            (200, Self.refResponse),
            (200, Self.commitResponse),
            (200, Self.treeResponse([Self.gone])),
            (201, #"{ "sha": "\#(String(repeating: "3", count: 40))" }"#),
            (201, #"{ "sha": "\#(String(repeating: "4", count: 40))" }"#),
            (422, #"{ "message": "Update is not a fast forward" }"#)
        ])
        await #expect(throws: AttachmentCleanupError.conflict) {
            try await self.makeGitHub(http).deleteAttachments(at: [Self.gone], in: "o/r")
        }
    }

    @Test func readsDiscussionBodyCommentsAndRepliesAcrossPages() async throws {
        let first = #"""
        { "data": { "repository": { "discussion": { "body": "本文", "author": { "login": "mrs1669" },
          "comments": { "pageInfo": { "hasNextPage": true, "endCursor": "c1" },
            "nodes": [{ "body": "Q1", "author": { "login": "mrs1669" },
              "replies": { "nodes": [{ "body": "回答: A", "author": { "login": "mrs1669" } }] } }] } } } } }
        """#
        let second = #"""
        { "data": { "repository": { "discussion": { "body": "本文", "author": { "login": "mrs1669" },
          "comments": { "pageInfo": { "hasNextPage": false, "endCursor": null },
            "nodes": [{ "body": "Q2", "author": null, "replies": { "nodes": [] } }] } } } } }
        """#
        let http = StubHTTPClient([first, second])
        let texts = try await makeGitHub(http).discussionTexts(in: "o/r", number: 12)

        #expect(texts == [
            AuthoredText(author: "mrs1669", body: "本文"),
            AuthoredText(author: "mrs1669", body: "Q1"),
            AuthoredText(author: "mrs1669", body: "回答: A"),
            AuthoredText(author: nil, body: "Q2")
        ])
        #expect(try requestJSON(http.requests[1]).variables["after"] as? String == "c1")
    }

    @Test func readsReviewCommentsOfChildPullRequests() async throws {
        let http = StubHTTPClient([
            #"[{ "number": 5 }, { "number": 3 }]"#,
            #"[{ "user": { "login": "mrs1669" }, "body": "ask3" }]"#,
            #"[{ "user": { "login": "mrs1669" }, "body": "ask5" }]"#
        ])
        let texts = try await makeGitHub(http).childPullRequestReviewComments(in: "o/r", base: "epic/mvp")

        #expect(texts.map(\.body) == ["ask3", "ask5"])
        #expect(http.requests.first?.url?.query()?.contains("base=epic/mvp") == true)
        let paths = http.requests.dropFirst().map { $0.url?.path() ?? "" }
        #expect(paths == ["/repos/o/r/pulls/3/comments", "/repos/o/r/pulls/5/comments"])
    }
}
