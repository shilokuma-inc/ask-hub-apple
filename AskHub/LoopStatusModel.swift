import AskHubKit
import Foundation
import Observation

/// 「ループ」タブ（リポジトリごとのループの状態）の一覧。表示だけで、止める・再開する操作は持たない
@MainActor
@Observable
final class LoopStatusModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// トークンが保存されていない
        case needsToken
        /// 直前の取得に失敗した。一覧は前回の結果を残す
        case failed(String)
    }

    private(set) var rows: [LoopStatusRow] = []
    private(set) var state = LoadState.idle
    /// 直前に取得を始めた時刻。自動更新（`refreshIfStale`）の間隔の判断に使う
    private(set) var lastRefreshed: Date?

    private let tokenStore: any TokenStore
    private let trustedAuthors: TrustedAuthors
    private let makeSource: @Sendable (String) -> any LoopStatusSource
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        trustedAuthors: TrustedAuthors = .default,
        makeSource: @escaping @Sendable (String) -> any LoopStatusSource = { GitHubLoopStatusSource(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.trustedAuthors = trustedAuthors
        self.makeSource = makeSource
    }

    var isLoading: Bool {
        state == .loading
    }

    /// ループの状態を取り直す
    func refresh() async {
        guard !isLoading else {
            needsRefreshAfterLoading = true
            return
        }
        repeat {
            needsRefreshAfterLoading = false
            await load()
        } while needsRefreshAfterLoading && !Task.isCancelled
    }

    /// 自動更新（フォアグラウンド復帰など）。取得中か、直前の取得から間もなければ取り直さない
    func refreshIfStale(now: Date = .now) async {
        guard !isLoading, AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now) else {
            return
        }
        await refresh()
    }

    private func load() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                rows = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed(InboxModel.message(for: error))
            return
        }
        let previous = (state: state, lastRefreshed: lastRefreshed)
        state = .loading
        lastRefreshed = .now
        do {
            let fetcher = LoopStatusFetcher(source: makeSource(token), trustedAuthors: trustedAuthors)
            rows = try await fetcher.rows(org: InboxModel.org)
            state = .loaded
        } catch {
            // バックグラウンドの取得が打ち切られた。失敗とは表示せず、次の自動更新で取り直せるようにする
            if Task.isCancelled {
                (state, lastRefreshed) = previous
                return
            }
            state = .failed(InboxModel.message(for: error))
        }
    }
}
