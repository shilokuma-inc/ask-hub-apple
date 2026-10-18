@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct GitHubSignInModelTests {
    /// 登録した順に本文を返す `HTTPClient`
    private final class StubHTTPClient: HTTPClient {
        private let bodies: OSAllocatedUnfairLock<[(status: Int, body: String)]>

        init(_ bodies: [(status: Int, body: String)]) {
            self.bodies = OSAllocatedUnfairLock(initialState: bodies)
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let next = bodies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let next, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (Data(next.body.utf8), response)
        }
    }

    private static let codeBody = """
        {"device_code":"dev","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """

    private func makeModel(_ bodies: [(status: Int, body: String)], store: InMemoryTokenStore) -> GitHubSignInModel {
        let flow = GitHubDeviceFlow(clientID: "Iv1.test", http: StubHTTPClient(bodies), sleep: { _ in })
        return GitHubSignInModel(flow: flow, store: store)
    }

    @Test func signInSavesTokenToStore() async throws {
        let store = InMemoryTokenStore()
        let model = makeModel([
            (200, Self.codeBody),
            (200, #"{"error":"authorization_pending"}"#),
            (200, #"{"access_token":"ghu_signed_in","token_type":"bearer"}"#)
        ], store: store)
        #expect(model.isAvailable)
        await model.signIn()
        #expect(model.phase == .signedIn)
        #expect(try store.load() == "ghu_signed_in")
    }

    @Test func deniedSignInKeepsStoreEmpty() async throws {
        let store = InMemoryTokenStore()
        let model = makeModel([(200, Self.codeBody), (200, #"{"error":"access_denied"}"#)], store: store)
        await model.signIn()
        #expect(model.phase == .failed(message: "GitHub での承認が取り消されました"))
        #expect(try store.load() == nil)
    }

    @Test func failureMessageDoesNotContainSecrets() {
        let message = GitHubSignInModel.message(for: GitHubDeviceFlow.Failure.oauth(code: "incorrect_device_code", description: "dev"))
        #expect(message == "GitHub でサインインできませんでした（incorrect_device_code）")
    }

    @Test func missingClientIDHidesSignIn() async {
        #expect(GitHubSignInModel.bundledFlow(info: [:]) == nil)
        #expect(GitHubSignInModel.bundledFlow(info: [GitHubSignInModel.clientIDKey: ""]) == nil)
        #expect(GitHubSignInModel.bundledFlow(info: [GitHubSignInModel.clientIDKey: "$(GITHUB_CLIENT_ID)"]) == nil)
        #expect(GitHubSignInModel.bundledFlow(info: [GitHubSignInModel.clientIDKey: "Iv1.abc"]) != nil)

        let model = GitHubSignInModel(flow: nil, store: InMemoryTokenStore())
        #expect(!model.isAvailable)
        await model.signIn()
        #expect(model.phase == .idle)
    }
}
