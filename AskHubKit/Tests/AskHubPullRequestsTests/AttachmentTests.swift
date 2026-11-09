@testable import AskHubPullRequests
import Foundation
import Testing

/// 最終 PR の本文に載せる画像の添付と、本文の書き換え
struct AttachmentTests {
    private static let asset = "https://github.com/user-attachments/assets/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

    @Test func uploadsToUserAttachmentsWithRepositoryID() async throws {
        let transport = StubTransport([.json(200, #"{"id":123456,"full_name":"shilokuma-inc/ask-hub-apple"}"#), .json(201, #"{"url":"\#(Self.asset)"}"#)])
        let url = try await Fixture.client(transport).uploadAttachment(Data([1, 2, 3]), name: "d1-after.png", contentType: "image/png")
        #expect(url == Self.asset)
        let (repository, upload) = (transport.requests[0], transport.requests[1])
        #expect(Fixture.path(repository) == "/repos/shilokuma-inc/ask-hub-apple")
        #expect(upload.httpMethod == "POST")
        #expect(upload.url?.host == "uploads.github.com")
        #expect(upload.url?.path == "/user-attachments/assets")
        let query = URLComponents(url: try #require(upload.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query == [.init(name: "name", value: "d1-after.png"), .init(name: "content_type", value: "image/png"), .init(name: "repository_id", value: "123456")])
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(upload.httpBody == Data([1, 2, 3]))
        #expect(upload.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func refusesUnexpectedAssetURLAndBadNames() async throws {
        let transport = StubTransport([.json(200, #"{"id":1}"#), .json(201, #"{"url":"https://example.com/a.png"}"#)])
        await #expect(throws: PullRequestError.malformed("添付の URL の形が違う")) {
            try await Fixture.client(transport).uploadAttachment(Data([1]), name: "a.png", contentType: "image/png")
        }
        await #expect(throws: PullRequestError.invalidArgument("添付の名前か種類の形が違う")) {
            try await Fixture.client(StubTransport([])).uploadAttachment(Data([1]), name: "../a.png", contentType: "image/png")
        }
        await #expect(throws: PullRequestError.invalidArgument("添付の大きさが 0 か、上限を超える")) {
            try await Fixture.client(StubTransport([])).uploadAttachment(Data(), name: "a.png", contentType: "image/png")
        }
    }

    @Test func updatesPullRequestBody() async throws {
        let transport = StubTransport([.json(200, Fixture.json(Fixture.pull(7)))])
        try await Fixture.client(transport).updateBody(number: 7, body: "本文")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/pulls/7")
        #expect(Fixture.body(request)["body"] as? String == "本文")
    }
}
