import AskHubKit
import Foundation
import Observation

/// 受信箱の一覧（要回答 / 急がない）の状態
@MainActor
@Observable
final class InboxModel {
    enum LoadState: Equatable {
        /// まだ取得していない
        case idle
        case loading
        case loaded
        /// トークンが保存されていない
        case needsToken
        /// 直前の取得に失敗した。一覧は前回の結果を残す
        case failed(String)
    }

    /// 対象の organization（Discussion #1 の Q6）
    static let org = "shilokuma-inc"

    private(set) var questions: [InboxQuestion] = []
    private(set) var issues: [InboxIssue] = []
    private(set) var state = LoadState.idle

    private let tokenStore: any TokenStore
    private let makeSource: @Sendable (String) -> any InboxSource
    private let trustedAuthors: TrustedAuthors

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        trustedAuthors: TrustedAuthors = .default,
        makeSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.trustedAuthors = trustedAuthors
        self.makeSource = makeSource
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    /// 保存済みのトークンで、要回答と急がないをまとめて取得し直す。
    /// 取得中に呼ばれた場合は、その取得が終わってから取り直す（設定でトークンを変えた直後など）
    func refresh() async {
        guard !isLoading else {
            needsRefreshAfterLoading = true
            return
        }
        repeat {
            needsRefreshAfterLoading = false
            await load()
        } while needsRefreshAfterLoading
    }

    private func load() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                questions = []
                issues = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed("Keychain からトークンを読み込めませんでした")
            return
        }

        state = .loading
        let fetcher = InboxFetcher(source: makeSource(token), trustedAuthors: trustedAuthors)
        do {
            async let questions = fetcher.unansweredQuestions(org: Self.org)
            async let issues = fetcher.lowPriorityIssues(org: Self.org)
            (self.questions, self.issues) = try await (questions, issues)
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// 取得の失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        switch error as? GitHubError {
        case .http(status: 401, _):
            "トークンが無効です。設定でトークンを保存し直してください"

        case let .http(status, message):
            "GitHub から取得できませんでした（HTTP \(status)\(message.map { ": \($0)" } ?? "")）"

        case let .rateLimited(retryAfter):
            "GitHub のレート制限中です。\(retryAfter.components.seconds) 秒ほど待ってから更新してください"

        case .graphQL, .invalidResponse:
            "GitHub の応答を読み取れませんでした"

        case nil:
            "GitHub から取得できませんでした（\(error.localizedDescription)）"
        }
    }
}
