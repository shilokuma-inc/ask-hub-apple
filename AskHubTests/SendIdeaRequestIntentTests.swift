@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct SendIdeaRequestIntentTests {
    private static let token = "github_pat_secret"

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
            Issue.record("依頼を送るだけで一覧を取得しない")
            return []
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            if let failure {
                throw failure
            }
            created.withLock { $0.append(request) }
            return CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            Issue.record("機能追加・修正の依頼だけを送る")
            throw IdeaRequestError.invalidRequest
        }
    }

    /// 読み込みで失敗する Keychain
    private struct FailingTokenStore: TokenStore {
        func load() throws -> String? { throw KeychainError(status: errSecInteractionNotAllowed) }
        func save(_ token: String) throws {}
        func delete() throws {}
    }

    private func makeSubmission(
        tokenStore: any TokenStore = InMemoryTokenStore(token: token),
        requester: RecordingRequester,
        usesSampleData: Bool = false,
        madeTokens: OSAllocatedUnfairLock<[String]> = OSAllocatedUnfairLock(initialState: [])
    ) -> IdeaRequestSubmission {
        IdeaRequestSubmission(
            requesters: IntentRequesterSource(
                tokenStore: tokenStore,
                makeRequester: { token in
                    madeTokens.withLock { $0.append(token) }
                    return requester
                },
                usesSampleData: { usesSampleData }
            )
        )
    }

    @Test func sendsIdeaRequestAndReturnsIssueURL() async throws {
        let requester = RecordingRequester()
        let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])

        let sent = try await makeSubmission(requester: requester, madeTokens: tokens).send(
            repository: "shilokuma-inc/ask-hub-apple",
            summary: " 通知の頻度を調整したい ",
            body: "1 日 1 回にまとめたい"
        )

        // アプリの「新しい依頼」と同じ形の依頼（要約と依頼文は別々。タイトルは `【依頼】<要約>`）
        #expect(requester.requests == [
            IdeaRequest(repository: "shilokuma-inc/ask-hub-apple", summary: " 通知の頻度を調整したい ", body: "1 日 1 回にまとめたい")
        ])
        #expect(requester.requests.first?.title == "【依頼】通知の頻度を調整したい")
        #expect(tokens.withLock { $0 } == [Self.token])
        #expect(sent == IntentSentRequest(
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/41")!,
            message: "ask-hub-apple に「通知の頻度を調整したい」を依頼しました"
        ))
    }

    @Test(arguments: ["", "  ", "1 行目\n2 行目"])
    func asksSummaryAgainWithoutSending(summary: String) async {
        let requester = RecordingRequester()

        await #expect(throws: IdeaRequestInputError.summary) {
            try await makeSubmission(requester: requester).send(repository: "o/r", summary: summary, body: "依頼文")
        }
        #expect(requester.requests.isEmpty)
    }

    @Test(arguments: ["", " \n "])
    func asksBodyAgainWithoutSending(body: String) async {
        let requester = RecordingRequester()

        await #expect(throws: IdeaRequestInputError.body) {
            try await makeSubmission(requester: requester).send(repository: "o/r", summary: "要約", body: body)
        }
        #expect(requester.requests.isEmpty)
    }

    @Test func rejectsInvalidRepository() async {
        let requester = RecordingRequester()

        let error = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(requester: requester).send(repository: "not a repo", summary: "要約", body: "依頼文")
        }
        #expect(error?.message == "リポジトリを選び、要約（1 行）と依頼文を入力してください")
        #expect(requester.requests.isEmpty)
    }

    @Test func explainsMissingToken() async {
        let requester = RecordingRequester()

        let error = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(tokenStore: InMemoryTokenStore(token: nil), requester: requester)
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }
        #expect(error?.message == "トークンが未設定です。設定で保存してください")
        #expect(requester.requests.isEmpty)
    }

    @Test func explainsKeychainFailure() async {
        let error = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(tokenStore: FailingTokenStore(), requester: RecordingRequester())
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }
        #expect(error?.message == "Keychain からトークンを読み込めませんでした")
    }

    @Test(arguments: [
        GitHubError.http(status: 401, message: "Bad credentials"),
        GitHubError.http(status: 403, message: "Resource not accessible by personal access token"),
        GitHubError.http(status: 404, message: "Not Found"),
        GitHubError.rateLimited(retryAfter: .seconds(60))
    ])
    func explainsGitHubFailureWithAppMessage(failure: GitHubError) async {
        let error = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(requester: RecordingRequester(failure: failure))
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }

        // アプリの「新しい依頼」と同じ文言で、トークンの値を含めない
        #expect(error?.message == IdeaRequestModel.message(for: failure))
        #expect(error?.message.contains(Self.token) == false)
    }

    @Test func explainsGitHubFailureMessages() async {
        let notFound = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(requester: RecordingRequester(failure: GitHubError.http(status: 404, message: "Not Found")))
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }
        #expect(notFound?.message == "GitHub とのやり取りに失敗しました（HTTP 404: Not Found）")

        let limited = await #expect(throws: AppIntentError.self) {
            try await makeSubmission(requester: RecordingRequester(failure: GitHubError.rateLimited(retryAfter: .seconds(60))))
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }
        #expect(limited?.message == "GitHub のレート制限中です。60 秒ほど待ってから更新してください")
    }

    @Test func passesCancellationThrough() async {
        await #expect(throws: CancellationError.self) {
            try await makeSubmission(requester: RecordingRequester(failure: CancellationError()))
                .send(repository: "o/r", summary: "要約", body: "依頼文")
        }
    }

    @Test func doesNotSendToGitHubInDemoMode() async throws {
        let requester = RecordingRequester()
        let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])

        let sent = try await makeSubmission(
            tokenStore: FailingTokenStore(),
            requester: requester,
            usesSampleData: true,
            madeTokens: tokens
        ).send(repository: "shilokuma-inc/notti-ios", summary: "要約", body: "依頼文")

        // GitHub の requester を作らない（トークンを読まない）
        #expect(tokens.withLock { $0 }.isEmpty)
        #expect(requester.requests.isEmpty)
        #expect(sent.url == URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/41"))
        #expect(sent.message == "notti-ios に「要約」を依頼しました（デモモードのため、GitHub には送っていません）")
    }
}
