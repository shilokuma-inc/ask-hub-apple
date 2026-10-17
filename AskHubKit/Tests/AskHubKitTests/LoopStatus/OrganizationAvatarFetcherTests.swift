@testable import AskHubKit
import Foundation
import os
import Testing

/// organization のアバター画像の取得（トークンを付けない・応答の検証）
struct OrganizationAvatarFetcherTests {
    /// 決まった応答を返し、受けたリクエストを残す
    final class StubAvatarHTTPClient: HTTPClient {
        private let state: OSAllocatedUnfairLock<[URLRequest]> = OSAllocatedUnfairLock(initialState: [])
        let status: Int
        let contentType: String?
        let body: Data

        init(status: Int = 200, contentType: String? = "image/png", body: Data = Data([0x89, 0x50, 0x4E, 0x47])) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        var requests: [URLRequest] {
            state.withLock { $0 }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            state.withLock { $0.append(request) }
            let headers = contentType.map { ["Content-Type": $0] } ?? [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
    }

    @Test func urlUsesAvatarsHostWithLoginAndSize() {
        let url = OrganizationAvatarFetcher.url(login: "shilokuma-inc", pixelSize: 60)
        #expect(url?.absoluteString == "https://avatars.githubusercontent.com/shilokuma-inc?size=60")
    }

    @Test func urlRejectsLoginsWithUnexpectedCharacters() {
        #expect(OrganizationAvatarFetcher.url(login: "", pixelSize: 60) == nil)
        #expect(OrganizationAvatarFetcher.url(login: "a/b", pixelSize: 60) == nil)
        #expect(OrganizationAvatarFetcher.url(login: "a?b", pixelSize: 60) == nil)
        #expect(OrganizationAvatarFetcher.url(login: "ａｂ", pixelSize: 60) == nil)
    }

    /// トークンを漏らさないため、リクエストに認証の情報を付けない
    @Test func requestHasNoAuthorizationHeader() async throws {
        let http = StubAvatarHTTPClient()
        let data = try await OrganizationAvatarFetcher(http: http).imageData(login: "shilokuma-inc", pixelSize: 60)
        #expect(data == http.body)
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?.isEmpty ?? true)
        #expect(request.url?.host == "avatars.githubusercontent.com")
    }

    @Test func avatarsSessionKeepsNoCookiesOrCredentials() {
        let configuration = URLSession.avatars.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpAdditionalHeaders?.isEmpty ?? true)
    }

    @Test func nonOKStatusFails() async {
        let fetcher = OrganizationAvatarFetcher(http: StubAvatarHTTPClient(status: 404))
        await #expect(throws: GitHubError.self) {
            try await fetcher.imageData(login: "shilokuma-inc", pixelSize: 60)
        }
    }

    @Test func nonImageResponseFails() async {
        let fetcher = OrganizationAvatarFetcher(http: StubAvatarHTTPClient(contentType: "text/html"))
        await #expect(throws: GitHubError.self) {
            try await fetcher.imageData(login: "shilokuma-inc", pixelSize: 60)
        }
    }

    @Test func emptyBodyFails() async {
        let fetcher = OrganizationAvatarFetcher(http: StubAvatarHTTPClient(body: Data()))
        await #expect(throws: GitHubError.self) {
            try await fetcher.imageData(login: "shilokuma-inc", pixelSize: 60)
        }
    }

    /// login に使えない文字なら通信しない
    @Test func invalidLoginDoesNotSendRequest() async {
        let http = StubAvatarHTTPClient()
        await #expect(throws: GitHubError.self) {
            try await OrganizationAvatarFetcher(http: http).imageData(login: "a/b", pixelSize: 60)
        }
        #expect(http.requests.isEmpty)
    }
}
