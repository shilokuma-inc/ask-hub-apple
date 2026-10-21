@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct RepositoryEntityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 依頼先の一覧を返す。取得した organization を記録し、失敗させることもできる
    private final class ListingRequester: IdeaRequesting {
        private let listed = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        private let repositories: [RequestRepository]
        private let failure: (any Error & Sendable)?

        init(repositories: [RequestRepository] = [], failure: (any Error & Sendable)? = nil) {
            self.repositories = repositories
            self.failure = failure
        }

        /// `repositories(in:)` に渡された organization（呼ばれた順）
        var listedOrganizations: [[String]] {
            listed.withLock { $0 }
        }

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
            listed.withLock { $0.append(orgs) }
            if let failure {
                throw failure
            }
            return repositories
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            Issue.record("依頼先の候補を出すだけで Issue を作らない")
            throw IdeaRequestError.invalidRequest
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            Issue.record("依頼先の候補を出すだけで Issue を作らない")
            throw IdeaRequestError.invalidRequest
        }
    }

    /// 読み込みで失敗する Keychain
    private struct FailingTokenStore: TokenStore {
        func load() throws -> String? { throw KeychainError(status: errSecInteractionNotAllowed) }
        func save(_ token: String) throws {}
        func delete() throws {}
    }

    private func makeCandidates(
        tokenStore: any TokenStore = InMemoryTokenStore(token: "github_pat_secret"),
        requester: ListingRequester,
        usesSampleData: Bool = false,
        madeTokens: OSAllocatedUnfairLock<[String]> = OSAllocatedUnfairLock(initialState: [])
    ) -> RepositoryCandidates {
        RepositoryCandidates(
            requesters: IntentRequesterSource(
                tokenStore: tokenStore,
                makeRequester: { token in
                    madeTokens.withLock { $0.append(token) }
                    return requester
                },
                usesSampleData: { usesSampleData }
            ),
            organizations: { ["shilokuma-inc", "shilokuma-labs"] }
        )
    }

    @Test func listsRepositoriesInPickerOrderWithSavedToken() async throws {
        let requester = ListingRequester(repositories: [
            RequestRepository(fullName: "shilokuma-inc/dotfiles"),
            RequestRepository(fullName: "shilokuma-inc/ask-hub-apple", lastSeen: now),
            RequestRepository(fullName: "shilokuma-labs/web-tools", lastSeen: now),
            RequestRepository(fullName: "shilokuma-labs/sandbox")
        ])
        let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])

        let candidates = try await makeCandidates(requester: requester, madeTokens: tokens).all(now: now)

        // アプリの依頼先の Picker と同じく、担当 PC ありを先に、その中を owner ごとに並べる
        #expect(candidates == [
            "shilokuma-inc/ask-hub-apple",
            "shilokuma-labs/web-tools",
            "shilokuma-inc/dotfiles",
            "shilokuma-labs/sandbox"
        ])
        #expect(requester.listedOrganizations == [["shilokuma-inc", "shilokuma-labs"]])
        #expect(tokens.withLock { $0 } == ["github_pat_secret"])
    }

    @Test func explainsMissingToken() async {
        let requester = ListingRequester()
        let error = await #expect(throws: AskHubIntentError.self) {
            try await makeCandidates(tokenStore: InMemoryTokenStore(token: nil), requester: requester).all(now: now)
        }

        #expect(error?.message == "トークンが未設定です。設定で保存してください")
        #expect(requester.listedOrganizations.isEmpty)
    }

    @Test func explainsKeychainFailure() async {
        let error = await #expect(throws: AskHubIntentError.self) {
            try await makeCandidates(tokenStore: FailingTokenStore(), requester: ListingRequester()).all(now: now)
        }

        #expect(error?.message == "Keychain からトークンを読み込めませんでした")
    }

    @Test(arguments: [
        (GitHubError.http(status: 401, message: "Bad credentials"), "トークンが無効です。設定でトークンを保存し直してください"),
        (GitHubError.rateLimited(retryAfter: .seconds(60)), "GitHub のレート制限中です。60 秒ほど待ってから更新してください")
    ])
    func explainsGitHubFailureWithAppMessage(failure: GitHubError, expected: String) async {
        let error = await #expect(throws: AskHubIntentError.self) {
            try await makeCandidates(requester: ListingRequester(failure: failure)).all(now: now)
        }

        // アプリの「新しい依頼」と同じ文言で、トークンの値を含めない
        #expect(error?.message == expected)
        #expect(error?.message == IdeaRequestModel.message(for: failure))
        #expect(error?.message.contains("github_pat_secret") == false)
    }

    @Test func passesCancellationThrough() async {
        // Siri を閉じたなどのキャンセルは、失敗の文言にしない
        await #expect(throws: CancellationError.self) {
            try await makeCandidates(requester: ListingRequester(failure: CancellationError())).all(now: now)
        }
    }

    @Test func usesSampleRepositoriesWithoutReadingTokenInDemoMode() async throws {
        let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])
        let requester = ListingRequester()

        let candidates = try await makeCandidates(
            tokenStore: FailingTokenStore(),
            requester: requester,
            usesSampleData: true,
            madeTokens: tokens
        ).all(now: .now)

        let sample = try await SampleIdeaRequester().repositories(in: [])
        #expect(Set(candidates) == Set(sample.map(\.fullName)))
        #expect(candidates.first == "shilokuma-inc/ask-hub-apple")
        // GitHub の requester を作らない（トークンを読まない）
        #expect(tokens.withLock { $0 }.isEmpty)
        #expect(requester.listedOrganizations.isEmpty)
    }

    @Test func makesEntitiesFromValidIdentifiersOnly() async throws {
        let entities = try await RepositoryEntityQuery().entities(for: ["shilokuma-inc/ask-hub-apple", "not a repo", "o/r/x", "o/r"])

        #expect(entities.map(\.id) == ["shilokuma-inc/ask-hub-apple", "o/r"])
    }
}
