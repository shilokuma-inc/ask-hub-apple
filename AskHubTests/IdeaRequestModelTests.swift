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

    /// 最初の一覧の取得を、テストが開けるまで止めておく
    private final class GatedRequester: IdeaRequesting {
        private let gate = OSAllocatedUnfairLock<(opened: Bool, waiters: [CheckedContinuation<Void, Never>])>(initialState: (false, []))

        func open() {
            let waiters = gate.withLock { state in
                state.opened = true
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }

        func repositories(in org: String) async throws -> [String] {
            await withCheckedContinuation { continuation in
                let opened = gate.withLock { state in
                    if !state.opened {
                        state.waiters.append(continuation)
                    }
                    return state.opened
                }
                if opened {
                    continuation.resume()
                }
            }
            return ["shilokuma-inc/ask-hub-apple"]
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            throw IdeaRequestError.invalidRequest
        }
    }

    @Test func reloadRequestedDuringLoadingUsesLatestToken() async throws {
        let store = InMemoryTokenStore(token: "github_pat_old")
        let requester = GatedRequester()
        let model = IdeaRequestModel(tokenStore: store) { _ in requester }

        let first = Task { await model.loadRepositories() }
        while model.repositoriesState != .loading {
            await Task.yield()
        }
        // 取得中に設定でトークンを削除して、シートを閉じた
        try store.delete()
        await model.loadRepositories()
        requester.open()
        await first.value

        // 古いトークンでの一覧を残さず、最新の状態（未設定）を反映する
        #expect(model.repositoriesState == .needsToken)
        #expect(model.repositories.isEmpty)
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
