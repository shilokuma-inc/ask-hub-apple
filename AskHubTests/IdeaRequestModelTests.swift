@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct IdeaRequestModelTests {
    /// 作った依頼を記録する。失敗させることもできる
    private final class RecordingRequester: IdeaRequesting {
        private let created = OSAllocatedUnfairLock<[IdeaRequest]>(initialState: [])
        private let failure: (any Error & Sendable)?

        init(failure: (any Error & Sendable)? = nil) {
            self.failure = failure
        }

        var requests: [IdeaRequest] {
            created.withLock { $0 }
        }

        func repositories(in org: String) async throws -> [String] {
            if let failure {
                throw failure
            }
            return ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios"]
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            if let failure {
                throw failure
            }
            created.withLock { $0.append(request) }
            return CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
        }
    }

    private func makeModel(token: String? = "github_pat_saved", requester: RecordingRequester) -> IdeaRequestModel {
        IdeaRequestModel(tokenStore: InMemoryTokenStore(token: token)) { _ in requester }
    }

    @Test func loadsRepositoriesAndKeepsSelectionOnlyIfStillListed() async {
        let model = makeModel(requester: RecordingRequester())
        model.repository = "shilokuma-inc/archived-app"
        await model.loadRepositories()

        #expect(model.repositoriesState == .loaded)
        #expect(model.repositories == ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios"])
        #expect(model.repository == nil)
    }

    @Test func needsTokenToListRepositories() async {
        let model = makeModel(token: nil, requester: RecordingRequester())
        await model.loadRepositories()
        #expect(model.repositoriesState == .needsToken)
    }

    @Test func sendsRequestAndClearsTextButKeepsRepository() async {
        let requester = RecordingRequester()
        let model = makeModel(requester: requester)
        #expect(!model.canSend)
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "通知の頻度を調整したい"
        model.body = "朝だけにしたい"
        #expect(model.canSend)

        await model.send()

        #expect(requester.requests == [IdeaRequest(repository: "shilokuma-inc/notti-ios", summary: "通知の頻度を調整したい", body: "朝だけにしたい")])
        #expect(model.created?.number == 41)
        #expect(model.summary.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.repository == "shilokuma-inc/notti-ios")
        #expect(model.errorMessage == nil)
    }

    @Test func keepsInputAndShowsErrorWhenSendingFails() async {
        let model = makeModel(requester: RecordingRequester(failure: GitHubError.http(status: 401, message: "Bad credentials")))
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "要約"
        model.body = "依頼文"
        await model.send()

        #expect(model.created == nil)
        #expect(model.summary == "要約")
        #expect(model.errorMessage == "トークンが無効です。設定でトークンを保存し直してください")
    }

    @Test func explainsMissingTokenWhenSending() async {
        let model = makeModel(token: nil, requester: RecordingRequester())
        model.repository = "o/r"
        model.summary = "要約"
        model.body = "依頼文"
        await model.send()
        #expect(model.errorMessage == "トークンが未設定です。設定で保存してください")
    }
}
