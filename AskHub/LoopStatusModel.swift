import AskHubKit
import Foundation
import Observation

/// 「ループ」タブ（リポジトリごとのループの状態と、その上の「上限で待機中」「ループの開始待ち」）の一覧。
/// 表示だけで、止める・再開する操作は持たない
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
    /// `ready-for-loop` を付けて、ループの開始を待っている Discussion
    private(set) var waiting: [WaitingDiscussion] = []
    /// 担当 PC が Claude の利用上限で待機しているリポジトリ
    private(set) var usageLimited: [UsageLimitedRepository] = []
    private(set) var state = LoadState.idle
    /// 直前に取得を始めた時刻。自動更新（`refreshIfStale`）の間隔の判断に使う
    private(set) var lastRefreshed: Date?

    private let tokenStore: any TokenStore
    private let trustedAuthors: TrustedAuthors
    private let makeSource: @Sendable (String) -> any LoopStatusSource
    /// 「上限で待機中」「ループの開始待ち」の取得元（受信箱と同じ取得元を使う）
    private let makeInboxSource: @Sendable (String) -> any InboxSource
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        trustedAuthors: TrustedAuthors = .default,
        makeSource: @escaping @Sendable (String) -> any LoopStatusSource = { GitHubLoopStatusSource(client: GitHubClient(token: $0)) },
        makeInboxSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.trustedAuthors = trustedAuthors
        self.makeSource = makeSource
        self.makeInboxSource = makeInboxSource
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 行も「上限で待機中」「ループの開始待ち」も無い（空の表示を出す）
    var isEmpty: Bool {
        rows.isEmpty && waiting.isEmpty && usageLimited.isEmpty
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
                waiting = []
                usageLimited = []
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
        let org = InboxModel.org
        let fetcher = LoopStatusFetcher(source: makeSource(token), trustedAuthors: trustedAuthors)
        let inboxFetcher = InboxFetcher(source: makeInboxSource(token), trustedAuthors: trustedAuthors)
        do {
            async let rows = fetcher.rows(org: org)
            async let waiting = inboxFetcher.waitingDiscussions(org: org)
            // 上限の表示は補助なので、取得に失敗してもループの状態は出す（次の更新で取り直す）
            async let usageLimited = (try? await inboxFetcher.usageLimitedRepositories(org: org, now: .now)) ?? []
            let fetched = try await (rows, waiting, usageLimited)
            // 上限の取得の `try?` は打ち切りも空として返すので、打ち切られていれば途中の結果で一覧を上書きしない
            try Task.checkCancellation()
            (self.rows, self.waiting, self.usageLimited) = fetched
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
