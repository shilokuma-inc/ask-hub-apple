@testable import AskHubKit
import Foundation
import os
import Testing

struct GitHubAttachmentUploaderTests {
    private static let ids = [
        "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    ]
    private static let blob = String(repeating: "b", count: 40)
    private static let commit = String(repeating: "c", count: 40)

    private func makeUploader(_ http: MockHTTPClient) -> GitHubAttachmentUploader {
        let index = OSAllocatedUnfairLock(initialState: 0)
        return GitHubAttachmentUploader(
            client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }),
            makeID: {
                let id = index.withLock { value in
                    defer { value += 1 }
                    return Self.ids[value % Self.ids.count]
                }
                return UUID(uuidString: id)!
            }
        )
    }

    private static func created(blob: String = blob, commit: String = commit) -> MockHTTPClient.Response {
        .init(status: 201, body: #"{ "content": { "sha": "\#(blob)", "path": "x" }, "commit": { "sha": "\#(commit)" } }"#)
    }

    private static func requestLine(_ request: URLRequest) -> String {
        "\(request.httpMethod ?? "") \(request.url?.path() ?? "")"
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let png = AttachmentFile(name: "design.png", type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
    private let memo = AttachmentFile(name: "../メモ.md", type: "text/markdown", data: Data("# メモ".utf8))

    @Test func uploadsFilesInOrderAndReturnsMarkers() async throws {
        let second = String(repeating: "d", count: 40)
        let http = MockHTTPClient([Self.created(), Self.created(blob: second, commit: second)])
        let markers = try await makeUploader(http).upload([png, memo], to: "shilokuma-inc/ask-hub-apple")

        #expect(http.requests.map(Self.requestLine) == [
            "PUT /repos/shilokuma-inc/ask-hub-apple/contents/files/\(Self.ids[0])/design.png",
            "PUT /repos/shilokuma-inc/ask-hub-apple/contents/files/\(Self.ids[1])/%E3%83%A1%E3%83%A2.md"
        ])
        let body = try Self.json(http.requests[0])
        #expect(body["branch"] as? String == "askhub/attachments")
        #expect(body["content"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect(body["message"] as? String == "[chore] 添付を追加: design.png")
        #expect(try Self.json(http.requests[1])["message"] as? String == "[chore] 添付を追加: メモ.md")

        #expect(markers == [
            AttachmentMarker(
                path: "files/\(Self.ids[0])/design.png", sha: Self.blob, commit: Self.commit, name: "design.png", size: 4, type: "image/png"
            ),
            AttachmentMarker(
                path: "files/\(Self.ids[1])/メモ.md", sha: second, commit: second, name: "../メモ.md", size: 8, type: "text/markdown"
            )
        ])
        #expect(markers.allSatisfy { $0.isWellFormed })
    }

    @Test func uploadsNothingForEmptyList() async throws {
        let http = MockHTTPClient([])
        #expect(try await makeUploader(http).upload([], to: "o/r").isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: [404, 422])
    func createsOrphanBranchWhenMissingThenRetries(status: Int) async throws {
        let http = MockHTTPClient([
            .init(status: status, body: #"{ "message": "Branch askhub/attachments not found" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "1", count: 40))" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "2", count: 40))" }"#),
            .init(status: 201, body: #"{ "ref": "refs/heads/askhub/attachments" }"#),
            Self.created()
        ])
        let markers = try await makeUploader(http).upload([png], to: "o/r")

        #expect(http.requests.map(Self.requestLine) == [
            "PUT /repos/o/r/contents/files/\(Self.ids[0])/design.png",
            "GET /repos/o/r/git/ref/heads/askhub/attachments",
            "POST /repos/o/r/git/trees",
            "POST /repos/o/r/git/commits",
            "POST /repos/o/r/git/refs",
            "PUT /repos/o/r/contents/files/\(Self.ids[0])/design.png"
        ])
        let tree = try #require(try Self.json(http.requests[2])["tree"] as? [[String: String]])
        #expect(tree.count == 1)
        #expect(tree.first?["path"] == "README.md")
        #expect(tree.first?["mode"] == "100644")
        #expect(tree.first?["type"] == "blob")
        #expect(tree.first?["content"] == GitHubAttachmentUploader.readme)
        let commit = try Self.json(http.requests[3])
        #expect(commit["tree"] as? String == String(repeating: "1", count: 40))
        #expect((commit["parents"] as? [String])?.isEmpty == true)
        let ref = try Self.json(http.requests[4])
        #expect(ref["ref"] as? String == "refs/heads/askhub/attachments")
        #expect(ref["sha"] as? String == String(repeating: "2", count: 40))
        #expect(markers.map(\.sha) == [Self.blob])
    }

    @Test func usesBranchCreatedConcurrently() async throws {
        // ref を作るときに 422（既にある）なら、ほかの送信が作ったブランチにそのまま上げる
        let http = MockHTTPClient([
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "1", count: 40))" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "2", count: 40))" }"#),
            .init(status: 422, body: #"{ "message": "Reference already exists" }"#),
            Self.created()
        ])
        #expect(try await makeUploader(http).upload([png], to: "o/r").count == 1)
        #expect(http.requests.count == 6)
    }

    @Test func doesNotCreateBranchTwice() async throws {
        let http = MockHTTPClient([
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "1", count: 40))" }"#),
            .init(status: 201, body: #"{ "sha": "\#(String(repeating: "2", count: 40))" }"#),
            .init(status: 201, body: #"{ "ref": "refs/heads/askhub/attachments" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#)
        ])
        await #expect(throws: AttachmentUploadError.missingContentsPermission) {
            try await makeUploader(http).upload([png], to: "o/r")
        }
        #expect(http.requests.count == 6)
    }

    @Test func reportsMissingPermissionWhenRepositoryIsInvisible() async throws {
        // リポジトリが見えないトークンでは、ref の確認もブランチの作成も 404 になる
        let http = MockHTTPClient([
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#)
        ])
        await #expect(throws: AttachmentUploadError.missingContentsPermission) {
            try await makeUploader(http).upload([png], to: "o/r")
        }
        #expect(http.requests.map(Self.requestLine).last == "POST /repos/o/r/git/trees")
    }

    @Test func reportsMissingPermissionWhenBranchExists() async throws {
        // ブランチはあるが書き込めない（404）。ブランチは作らない
        let http = MockHTTPClient([
            .init(status: 404, body: #"{ "message": "Not Found" }"#),
            .init(status: 200, body: #"{ "ref": "refs/heads/askhub/attachments" }"#)
        ])
        await #expect(throws: AttachmentUploadError.missingContentsPermission) {
            try await makeUploader(http).upload([png], to: "o/r")
        }
        #expect(http.requests.count == 2)
    }

    @Test func passesThroughOtherValidationError() async throws {
        let http = MockHTTPClient([
            .init(status: 422, body: #"{ "message": "Invalid request" }"#),
            .init(status: 200, body: #"{ "ref": "refs/heads/askhub/attachments" }"#)
        ])
        await #expect(throws: GitHubError.http(status: 422, message: "Invalid request")) {
            try await makeUploader(http).upload([png], to: "o/r")
        }
    }

    @Test func reportsForbiddenAsMissingPermission() async throws {
        let http = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: AttachmentUploadError.missingContentsPermission) {
            try await makeUploader(http).upload([png, memo], to: "o/r")
        }
        // 1 つ目で失敗したら、2 つ目は上げない
        #expect(http.requests.count == 1)
    }

    @Test func retriesConflictThenSucceeds() async throws {
        let conflict = MockHTTPClient.Response(status: 409, body: #"{ "message": "is at abc but expected def" }"#)
        let http = MockHTTPClient([conflict, conflict, Self.created()])
        #expect(try await makeUploader(http).upload([png], to: "o/r").count == 1)
        // 再試行でも同じパスに上げる
        #expect(Set(http.requests.map(Self.requestLine)) == ["PUT /repos/o/r/contents/files/\(Self.ids[0])/design.png"])
        #expect(http.requests.count == 3)
    }

    @Test func givesUpAfterRepeatedConflicts() async throws {
        let conflict = MockHTTPClient.Response(status: 409, body: #"{ "message": "conflict" }"#)
        let http = MockHTTPClient(Array(repeating: conflict, count: GitHubAttachmentUploader.maxConflictRetries + 1))
        await #expect(throws: AttachmentUploadError.conflict) {
            try await makeUploader(http).upload([png], to: "o/r")
        }
        #expect(http.requests.count == GitHubAttachmentUploader.maxConflictRetries + 1)
    }

    @Test func keepsSpecialCharactersInPathEncoded() async throws {
        let http = MockHTTPClient([Self.created()])
        let file = AttachmentFile(name: "a b?c#d%e.txt", type: "text/plain", data: Data("x".utf8))
        let markers = try await makeUploader(http).upload([file], to: "o/r")
        #expect(http.requests.first?.url?.absoluteString
            == "https://api.github.com/repos/o/r/contents/files/\(Self.ids[0])/a%20b%3Fc%23d%25e.txt")
        #expect(markers.first?.path == "files/\(Self.ids[0])/a b?c#d%e.txt")
    }

    @Test func doesNotLeakToken() async throws {
        let http = MockHTTPClient([.init(status: 500, body: #"{ "message": "boom" }"#)])
        do {
            _ = try await makeUploader(http).upload([png], to: "o/r")
            Issue.record("失敗するはず")
        } catch {
            #expect(!String(describing: error).contains("github_pat_secret"))
        }
    }
}
