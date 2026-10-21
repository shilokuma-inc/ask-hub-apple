@testable import AskHubKit
import Foundation
import Testing

struct GitBlobSHATests {
    @Test func matchesGitHashObject() {
        // `git hash-object` と同じ値
        #expect(GitBlobSHA.of(Data("hello world\n".utf8)) == "3b18e512dba79e4c8300dd08aeb37f8e728b8dad")
        #expect(GitBlobSHA.of(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }
}

struct GitHubAttachmentFetcherTests {
    private static let content = Data("hello world\n".utf8)
    private static let sha = "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"

    private func makeFetcher(_ http: MockHTTPClient) -> GitHubAttachmentFetcher {
        GitHubAttachmentFetcher(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private static func marker(sha: String = sha, size: Int = content.count) -> AttachmentMarker {
        AttachmentMarker(
            path: "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/hello.txt",
            sha: sha,
            commit: String(repeating: "c", count: 40),
            name: "hello.txt",
            size: size,
            type: "text/plain"
        )
    }

    private static func blob(
        _ data: Data,
        size: Int? = nil,
        encoding: String = "base64",
        lineBreaks: Bool = false
    ) -> MockHTTPClient.Response {
        let base64 = lineBreaks
            ? data.base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r\n", with: "\n")
            : data.base64EncodedString()
        let escaped = base64.replacingOccurrences(of: "\n", with: "\\n")
        let body = #"{ "sha": "\#(sha)", "size": \#(size ?? data.count), "encoding": "\#(encoding)", "content": "\#(escaped)" }"#
        return .init(status: 200, body: body)
    }

    @Test func fetchesBlobBySHAAndVerifies() async throws {
        let http = MockHTTPClient([Self.blob(Self.content)])
        let data = try await makeFetcher(http).fetch(Self.marker(), from: "shilokuma-inc/ask-hub-apple")

        #expect(data == Self.content)
        // ブランチのパス（contents）からではなく、blob SHA で取る
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /repos/shilokuma-inc/ask-hub-apple/git/blobs/\(Self.sha)"
        ])
    }

    @Test func decodesBase64WithLineBreaks() async throws {
        // GitHub の応答の base64 には改行が入る。改行の入る長さの中身で確かめる
        let content = Data((0..<300).map { UInt8($0 % 256) })
        let marker = AttachmentMarker(
            path: "files/3f2504e0-4f89-11d3-9a0c-0305e82c3301/a.png",
            sha: GitBlobSHA.of(content),
            commit: String(repeating: "c", count: 40),
            name: "a.png",
            size: content.count,
            type: "image/png"
        )
        let http = MockHTTPClient([Self.blob(content, lineBreaks: true)])
        #expect(try await makeFetcher(http).fetch(marker, from: "o/r") == content)
    }

    @Test func rejectsSizeMismatchBeforeDecoding() async {
        let http = MockHTTPClient([Self.blob(Self.content, size: 999)])
        await #expect(throws: AttachmentFetchError.sizeMismatch(expected: Self.content.count, actual: 999)) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func rejectsDecodedSizeMismatch() async {
        // 応答の size が目印と合っていても、戻した中身の大きさで確かめる
        let http = MockHTTPClient([Self.blob(Data("hello".utf8), size: Self.content.count)])
        await #expect(throws: AttachmentFetchError.sizeMismatch(expected: Self.content.count, actual: 5)) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func rejectsSHAMismatch() async {
        // 大きさは同じで中身が違う
        let tampered = Data("HELLO WORLD\n".utf8)
        let http = MockHTTPClient([Self.blob(tampered)])
        await #expect(throws: AttachmentFetchError.shaMismatch) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func reportsNotFound() async {
        let http = MockHTTPClient([.init(status: 404, body: #"{ "message": "Not Found" }"#)])
        await #expect(throws: AttachmentFetchError.notFound) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func passesThroughForbidden() async {
        let http = MockHTTPClient([.init(status: 403, body: #"{ "message": "Forbidden" }"#)])
        await #expect(throws: GitHubError.http(status: 403, message: "Forbidden")) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func rejectsUnknownEncoding() async {
        let http = MockHTTPClient([Self.blob(Self.content, encoding: "utf-8")])
        await #expect(throws: AttachmentFetchError.invalidContent) {
            try await makeFetcher(http).fetch(Self.marker(), from: "o/r")
        }
    }

    @Test func refusesMalformedMarkerWithoutRequest() async {
        let http = MockHTTPClient([])
        await #expect(throws: AttachmentFetchError.malformedMarker) {
            try await makeFetcher(http).fetch(Self.marker(sha: "../../contents/x"), from: "o/r")
        }
        #expect(http.requests.isEmpty)
    }
}
