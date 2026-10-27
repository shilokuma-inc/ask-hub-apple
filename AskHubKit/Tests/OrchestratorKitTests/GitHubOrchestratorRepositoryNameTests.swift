import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 担当リポジトリの今の名前（Issue #757）
extension GitHubOrchestratorTests {
    @Test func readsCurrentNameOfTransferredRepository() async throws {
        let http = StubHTTPClient([#"{ "data": { "repository": { "nameWithOwner": "tm-family/quiz-ios" } } }"#])

        let name = try await makeGitHub(http).currentName(of: "shilokuma-inc/quiz-ios")

        #expect(name == "tm-family/quiz-ios")
        // REST のリダイレクトを通らないよう、GraphQL で旧名のまま問い合わせる
        #expect(http.requests.map { $0.url?.path() } == ["/graphql"])
        let (_, variables) = try requestJSON(try #require(http.requests.first))
        #expect(variables["owner"] as? String == "shilokuma-inc")
        #expect(variables["name"] as? String == "quiz-ios")
    }

    @Test func throwsWhenRepositoryCannotBeResolved() async {
        // 削除済み・権限なし
        let missing = StubHTTPClient([
            #"{ "data": { "repository": null }, "errors": [{ "message": "Could not resolve to a Repository with the name 'o/r'." }] }"#
        ])
        await #expect(throws: GitHubError.self) {
            try await makeGitHub(missing).currentName(of: "o/r")
        }

        let empty = StubHTTPClient([#"{ "data": { "repository": null } }"#])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeGitHub(empty).currentName(of: "o/r")
        }

        // owner/name の形でなければ問い合わせない
        let invalid = StubHTTPClient([])
        await #expect(throws: GitHubError.invalidResponse) {
            try await makeGitHub(invalid).currentName(of: "quiz-ios")
        }
        #expect(invalid.requests.isEmpty)
    }
}
