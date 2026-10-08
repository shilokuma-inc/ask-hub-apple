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
    /// 開いている手動ループ（`manual-loop` の Discussion）と担当者
    private(set) var manualLoops: [ManualLoopEpic] = []
    /// `needs-answer` が付いている Discussion / PR（`owner/repo#番号` の小文字）。手動ループの回答待ちが終わったかの判定に使う
    private(set) var needsAnswer: Set<String> = []
    /// トークンの持ち主の login。自分が担当の手動ループを見分けるのに使う
    private(set) var viewerLogin: String?
    private(set) var state = LoadState.idle
    /// 直前に取得を始めた時刻。自動更新（`refreshIfStale`）の間隔の判断に使う
    private(set) var lastRefreshed: Date?

    private let tokenStore: any TokenStore
    /// リポジトリごとの信用する author（トークンごと）
    private let makeTrust: @Sendable (String) -> any TrustedAuthorsResolving
    /// トークンの持ち主の login の取得に使う
    private let makeStarter: @Sendable (String) -> any LoopStarting
    private let makeSource: @Sendable (String) -> any LoopStatusSource
    /// 「上限で待機中」「ループの開始待ち」の取得元（受信箱と同じ取得元を使う）
    private let makeInboxSource: @Sendable (String) -> any InboxSource
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeSource: @escaping @Sendable (String) -> any LoopStatusSource = { GitHubLoopStatusSource(client: GitHubClient(token: $0)) },
        makeInboxSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) },
        organizations: @escaping () -> [String] = { OrganizationSettings.load() },
        makeTrust: @escaping @Sendable (String) -> any TrustedAuthorsResolving = { RepositoryTrustCache.trust(token: $0) },
        makeStarter: @escaping @Sendable (String) -> any LoopStarting = { GitHubLoopStarter(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.makeTrust = makeTrust
        self.makeStarter = makeStarter
        self.organizations = organizations
        self.makeSource = makeSource
        self.makeInboxSource = makeInboxSource
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 行も「上限で待機中」「ループの開始待ち」も無い（空の表示を出す）
    var isEmpty: Bool {
        rows.isEmpty && waiting.isEmpty && usageLimited.isEmpty && manualLoops.isEmpty
    }

    /// 「手動ループ」の行
    func manualLoopItems(now: Date) -> [ManualLoopItem] {
        ManualLoopItem.items(epics: manualLoops, rows: rows, viewer: viewerLogin, needsAnswer: needsAnswer, now: now)
    }

    /// リポジトリのループをだれが回しているか
    func mode(of row: LoopStatusRow) -> LoopMode {
        row.mode(manualLoops: manualLoops)
    }

    /// 人が見るべき異常の数（タブのバッジ）。異常終了・長く動きが無い・担当 PC がいない進行中の epic・状態が途絶えた手動ループ
    func abnormalCount(now: Date) -> Int {
        var repositories = Set(rows.filter { $0.isAbnormal(now: now) }.map { $0.repository.lowercased() })
        for item in manualLoopItems(now: now) where item.isStale {
            repositories.insert(item.epic.subject.repository.lowercased())
        }
        return repositories.count
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
                manualLoops = []
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
        let orgs = organizations()
        let trust = makeTrust(token)
        let fetcher = LoopStatusFetcher(source: makeSource(token), trustedAuthors: trust)
        let inboxFetcher = InboxFetcher(source: makeInboxSource(token), trustedAuthors: trust)
        do {
            async let rows = fetcher.rows(orgs: orgs)
            async let waiting = inboxFetcher.waitingDiscussions(orgs: orgs)
            // 上限の表示は補助なので、取得に失敗してもループの状態は出す（次の更新で取り直す）
            async let usageLimited = (try? await inboxFetcher.usageLimitedRepositories(orgs: orgs, now: .now)) ?? []
            async let manualLoops = inboxFetcher.manualLoopEpics(orgs: orgs)
            // 回答待ちの判定と自分の login は補助なので、取れなくても状態は出す
            async let needsAnswer = (try? await inboxFetcher.subjectsNeedingAnswer(orgs: orgs)) ?? []
            // トークンを変えると別のアカウントになりうるので、毎回取り直す（軽い GraphQL 1 回）
            async let viewer = try? await makeStarter(token).viewerLogin()
            let fetched = try await (rows, waiting, usageLimited)
            let (fetchedManualLoops, fetchedNeedsAnswer, fetchedViewer) = try await (manualLoops, needsAnswer, viewer)
            // 上限の取得の `try?` は打ち切りも空として返すので、打ち切られていれば途中の結果で一覧を上書きしない
            try Task.checkCancellation()
            (self.rows, self.waiting, self.usageLimited) = fetched
            self.manualLoops = fetchedManualLoops
            self.needsAnswer = Set(fetchedNeedsAnswer.map { "\($0.repository)#\($0.number)".lowercased() })
            self.viewerLogin = fetchedViewer
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
