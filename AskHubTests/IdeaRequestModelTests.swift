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

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
            if let failure {
                throw failure
            }
            return [
                RequestRepository(fullName: "shilokuma-inc/ask-hub-apple", lastSeen: Date(timeIntervalSince1970: 1_800_000_000)),
                RequestRepository(fullName: "shilokuma-inc/notti-ios")
            ]
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            if let failure {
                throw failure
            }
            // 1 件目が #41、以降は 1 つずつ増やす
            let number = created.withLock {
                $0.append(request)
                return 40 + $0.count
            }
            return CreatedIssue(number: number, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/\(number)")!)
        }

        private let repositoryRequests = OSAllocatedUnfairLock<[String]>(initialState: [])

        /// 作った作成・削除の依頼（`<依頼 Issue のリポジトリ> <タイトル>`）
        var sentRepositoryRequests: [String] {
            repositoryRequests.withLock { $0 }
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            if let failure {
                throw failure
            }
            repositoryRequests.withLock { $0.append("\(repository) \(request.title)") }
            return CreatedIssue(number: 9, htmlURL: URL(string: "https://github.com/\(repository)/issues/9")!)
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
        #expect(model.repositories.map(\.fullName) == ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios"])
        #expect(model.repository == nil)
        #expect(model.repositorySections(now: Date(timeIntervalSince1970: 1_800_000_000)) == [
            RepositorySection(title: "担当 PC あり", repositories: ["shilokuma-inc/ask-hub-apple"]),
            RepositorySection(title: "担当 PC なし", repositories: ["shilokuma-inc/notti-ios"])
        ])
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

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
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
            return [RequestRepository(fullName: "shilokuma-inc/ask-hub-apple")]
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            throw IdeaRequestError.invalidRequest
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
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
        #expect(model.sent.map(\.issue.number) == [41])
        #expect(model.summary.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.repository == "shilokuma-inc/notti-ios")
        #expect(model.errorMessage == nil)
    }

    @Test func keepsSentRepositoryAndSummaryAfterChangingSelection() async throws {
        let model = makeModel(requester: RecordingRequester())
        model.repository = "shilokuma-inc/ask-hub-apple"
        model.summary = "  通知の頻度を調整したい "
        model.body = "朝だけにしたい"
        await model.send()

        // 続けて依頼しようとリポジトリと入力を変えても、送信結果は送った時点のまま
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "次の依頼"

        let sent = try #require(model.sent.first)
        #expect(sent.repository == "shilokuma-inc/ask-hub-apple")
        #expect(sent.summary == "通知の頻度を調整したい")
        #expect(sent.message == "ask-hub-apple に「通知の頻度を調整したい」を依頼しました")
        #expect(sent.linkTitle == "ask-hub-apple#41 を GitHub で開く")
        #expect(sent.issue.htmlURL == URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/41"))
        #expect(model.body.isEmpty)
    }

    @Test func keepsEverySentRequestNewestFirst() async {
        let model = makeModel(requester: RecordingRequester())
        model.repository = "shilokuma-inc/ask-hub-apple"
        model.summary = "1 件目"
        model.body = "依頼文"
        await model.send()
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "2 件目"
        model.body = "依頼文"
        await model.send()

        // 直前の 1 件で上書きせず、新しい順に残す
        #expect(model.sent.map(\.message) == [
            "notti-ios に「2 件目」を依頼しました",
            "ask-hub-apple に「1 件目」を依頼しました"
        ])
        #expect(model.sent.map(\.linkTitle) == ["notti-ios#42 を GitHub で開く", "ask-hub-apple#41 を GitHub で開く"])
    }

    @Test func doesNotAddFailedRequestToSentList() async {
        let failure = GitHubError.http(status: 401, message: "Bad credentials")
        let model = makeModel(requester: RecordingRequester(failure: failure))
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "要約"
        model.body = "依頼文"
        await model.send()
        await model.send()

        #expect(model.sent.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func startsWithEmptySentListWhenModelIsRecreated() async {
        let requester = RecordingRequester()
        let model = makeModel(requester: requester)
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "要約"
        model.body = "依頼文"
        await model.send()
        #expect(model.sent.count == 1)

        // 一覧は保存しないので、作り直したモデル（アプリの再起動・デモモードの切り替え）には残らない
        #expect(makeModel(requester: requester).sent.isEmpty)
    }

    @Test func keepsInputAndShowsErrorWhenSendingFails() async {
        let model = makeModel(requester: RecordingRequester(failure: GitHubError.http(status: 401, message: "Bad credentials")))
        model.repository = "shilokuma-inc/notti-ios"
        model.summary = "要約"
        model.body = "依頼文"
        await model.send()

        #expect(model.sent.isEmpty)
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
    // MARK: - 担当リポジトリの作成・削除の依頼

    private static let createRequest = RepositoryRequest.create(NewRepository(
        repository: "shilokuma-inc/my-quiz-ios",
        template: .quiz,
        appName: "MyQuiz",
        bundleIdentifier: "jp.shilokuma.MyQuiz"
    ))

    @Test func sendsRepositoryRequestToGivenRepository() async {
        let requester = RecordingRequester()
        let model = makeModel(requester: requester)

        let sent = await model.send(Self.createRequest, to: "shilokuma-inc/ask-hub-apple")

        #expect(requester.sentRepositoryRequests == ["shilokuma-inc/ask-hub-apple 【新規アプリ】shilokuma-inc/my-quiz-ios"])
        #expect(sent?.message == "my-quiz-ios の作成を依頼しました")
        #expect(sent?.linkTitle == "ask-hub-apple#9 を GitHub で開く")
        #expect(model.sentRepositoryRequests.count == 1)
        #expect(model.repositoryRequestError == nil)
    }

    @Test func refusesInvalidRepositoryRequestWithoutSending() async {
        let requester = RecordingRequester()
        let model = makeModel(requester: requester)

        // 依頼先を選んでいない
        #expect(await model.send(Self.createRequest, to: "") == nil)

        #expect(requester.sentRepositoryRequests.isEmpty)
        #expect(model.repositoryRequestError == "依頼先を選び、各項目を正しい形式で入力してください")
    }

    @Test func showsErrorWhenRepositoryRequestFails() async {
        let model = makeModel(token: nil, requester: RecordingRequester())

        let removal = RepositoryRequest.remove(RepositoryRemoval(repository: "shilokuma-inc/notti-ios", deletesLocalFiles: true))
        #expect(await model.send(removal, to: "shilokuma-inc/notti-ios") == nil)

        #expect(model.repositoryRequestError == "トークンが未設定です。設定で保存してください")
        #expect(model.sentRepositoryRequests.isEmpty)
    }

    @Test func listsOnlyAssignedRepositoriesForCreation() async {
        let model = makeModel(requester: RecordingRequester())
        await model.loadRepositories()

        #expect(model.assignedRepositories(now: Date(timeIntervalSince1970: 1_800_000_000)) == ["shilokuma-inc/ask-hub-apple"])
    }
}
