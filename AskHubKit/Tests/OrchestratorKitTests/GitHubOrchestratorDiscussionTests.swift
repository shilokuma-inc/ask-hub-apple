import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - ready-for-loop の Discussion へのコメント

extension GitHubOrchestratorTests {
    @Test func commentsOnReadyDiscussionWithGraphQL() async throws {
        let http = StubHTTPClient([#"{ "data": { "addDiscussionComment": { "comment": { "id": "DC_1" } } } }"#])
        try await makeGitHub(http).comment(on: .fixture(number: 12), body: "やることがありません")

        let mutation = try requestJSON(http.requests[0])
        #expect(mutation.query.contains("addDiscussionComment"))
        #expect(mutation.variables["discussion"] as? String == ReadyDiscussion.fixture(number: 12).nodeID)
        #expect(mutation.variables["body"] as? String == "やることがありません")
    }

    @Test func failsToCommentWhenPayloadIsNull() async throws {
        // 権限不足などでは payload が null になる。失敗として返し、呼び出し側が次のポーリングで再試行する
        let http = StubHTTPClient([#"{ "data": { "addDiscussionComment": null } }"#])
        await #expect(throws: (any Error).self) {
            try await self.makeGitHub(http).comment(on: .fixture(number: 12), body: "x")
        }
    }
}

// MARK: - 依頼先のリポジトリの Discussions の設定（Issue #719）

extension GitHubOrchestratorTests {
    @Test func readsDiscussionSettingsWithGraphQL() async throws {
        let http = StubHTTPClient([
            #"""
            { "data": { "repository": { "hasDiscussionsEnabled": true,
              "discussionCategories": { "nodes": [{ "name": "General" }, null, { "name": "Ideas" }] } } } }
            """#,
            // 無効なリポジトリでは、カテゴリは空で返る
            #"{ "data": { "repository": { "hasDiscussionsEnabled": false, "discussionCategories": { "nodes": [] } } } }"#
        ])
        let github = makeGitHub(http)

        #expect(try await github.discussionSettings(in: "o/r") == DiscussionSettings(isEnabled: true, categories: ["General", "Ideas"]))
        #expect(try await github.discussionSettings(in: "o/r") == DiscussionSettings(isEnabled: false, categories: []))
        let query = try requestJSON(http.requests[0])
        #expect(query.query.contains("hasDiscussionsEnabled"))
        #expect(query.variables["owner"] as? String == "o")
        #expect(query.variables["name"] as? String == "r")
    }

    @Test func failsToReadDiscussionSettingsOfMissingRepository() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": null } }"#])
        await #expect(throws: (any Error).self) {
            _ = try await self.makeGitHub(http).discussionSettings(in: "o/r")
        }
    }

    @Test func enablesDiscussionsWithRepositoryPatch() async throws {
        let http = StubHTTPClient([#"{ "full_name": "o/r", "has_discussions": true }"#])
        try await makeGitHub(http).enableDiscussions(in: "o/r")

        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["PATCH /repos/o/r"])
        let body = try #require(http.requests[0].httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: Bool] == ["has_discussions": true])
    }
}

// MARK: - 依頼から作った Discussion への添付欄（Discussion #669）

extension GitHubOrchestratorTests {
    private static let attachment = AttachmentMarker(
        path: "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/design.png",
        sha: String(repeating: "b", count: 40),
        commit: String(repeating: "c", count: 40),
        name: "design.png",
        size: 2_048,
        type: "image/png"
    )

    private static func discussionBody(_ body: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["data": ["repository": ["discussion": ["id": "D_12", "body": body]]]])
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    @Test func appendsAttachmentSectionToDiscussionBody() async throws {
        let http = StubHTTPClient([
            Self.discussionBody("## 依頼の要約\n通知を朝だけにしたい"),
            #"{ "data": { "updateDiscussion": { "discussion": { "id": "D_12" } } } }"#
        ])
        try await makeGitHub(http).appendAttachments([Self.attachment], toDiscussion: 12, in: "shilokuma-inc/ask-hub-apple")

        let query = try requestJSON(http.requests[0])
        #expect(query.query.contains("discussion(number: $number)"))
        #expect(query.variables["owner"] as? String == "shilokuma-inc")
        #expect(query.variables["name"] as? String == "ask-hub-apple")
        #expect(query.variables["number"] as? Int == 12)
        let mutation = try requestJSON(http.requests[1])
        #expect(mutation.query.contains("updateDiscussion"))
        #expect(mutation.variables["id"] as? String == "D_12")
        let body = try #require(mutation.variables["body"] as? String)
        let expected = AttachmentSection.appending([Self.attachment], to: "## 依頼の要約\n通知を朝だけにしたい", repository: "shilokuma-inc/ask-hub-apple")
        #expect(body == expected)
    }

    @Test func doesNotUpdateWhenMarkersAreAlreadyInBody() async throws {
        // 前の周回で足し終えていれば、同じ目印を重ねず、本文も更新しない
        let existing = AttachmentSection.appending([Self.attachment], to: "要約", repository: "o/r")
        let http = StubHTTPClient([Self.discussionBody(existing)])
        try await makeGitHub(http).appendAttachments([Self.attachment], toDiscussion: 12, in: "o/r")
        #expect(http.requests.count == 1)
    }

    @Test func failsToAppendWhenPayloadIsNull() async throws {
        let http = StubHTTPClient([Self.discussionBody("要約"), #"{ "data": { "updateDiscussion": null } }"#])
        await #expect(throws: (any Error).self) {
            try await self.makeGitHub(http).appendAttachments([Self.attachment], toDiscussion: 12, in: "o/r")
        }
    }

    @Test func failsWhenDiscussionIsMissing() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": { "discussion": null } } }"#])
        await #expect(throws: (any Error).self) {
            try await self.makeGitHub(http).appendAttachments([Self.attachment], toDiscussion: 12, in: "o/r")
        }
        #expect(http.requests.count == 1)
    }
}
