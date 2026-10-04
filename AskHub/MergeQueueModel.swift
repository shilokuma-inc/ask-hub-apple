import AskHubKit
import Foundation
import Observation

/// 「マージ待ち」（epic-final の PR）の一覧とマージの状態（Discussion #1 の Q13）
@MainActor
@Observable
final class MergeQueueModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// トークンが保存されていない
        case needsToken
        /// 直前の取得に失敗した。一覧は前回の結果を残す
        case failed(String)
    }

    private(set) var pullRequests: [EpicPullRequest] = []
    private(set) var state = LoadState.idle

    private let tokenStore: any TokenStore
    private let makeProvider: @Sendable (String) -> any MergeQueueProviding
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeProvider: @escaping @Sendable (String) -> any MergeQueueProviding = { GitHubMergeQueue(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.makeProvider = makeProvider
    }

    var isLoading: Bool {
        state == .loading
    }

    /// マージ待ちの PR を取り直す
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
                pullRequests = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        state = .loading
        do {
            pullRequests = try await makeProvider(token).epicPullRequests(org: InboxModel.org)
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// merge commit でマージし、epic ブランチを削除する。成功したら一覧から外して取り直す
    func merge(_ pullRequest: EpicPullRequest) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        do {
            try await makeProvider(token).merge(pullRequest)
        } catch MergeQueueError.branchNotDeleted {
            // マージはできている。ブランチが残ったことはエラーとして伝えるが、一覧からは外す
            pullRequests.removeAll { $0.id == pullRequest.id }
            await refresh()
            throw MergeQueueError.branchNotDeleted(pullRequest.headBranch)
        }
        pullRequests.removeAll { $0.id == pullRequest.id }
        await refresh()
    }

    /// マージするときのトークンが無い
    struct MissingTokenError: Error {}

    /// 失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        switch error {
        case is MissingTokenError:
            return "トークンが未設定です。設定で保存してください"

        case let MergeQueueError.notMergeable(reason):
            return "マージできません: \(reason)"

        case let MergeQueueError.branchNotDeleted(branch):
            return "マージしましたが、ブランチ \(branch) を削除できませんでした。GitHub で削除してください"

        case GitHubError.http(status: 409, _):
            return "確認した後に PR が更新されました。内容を確かめ直してからマージしてください"

        case GitHubError.http(status: 405, let message):
            return "GitHub がマージを受け付けませんでした" + (message.map { "（\($0)）" } ?? "")

        default:
            return InboxModel.message(for: error)
        }
    }
}
