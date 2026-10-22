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
    /// ビルドの Mac の状態（信用する author の `build-hosts` の Issue）。無ければ `nil`
    private(set) var buildHosts: BuildHostsStatus?
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
    /// epic の最終 PR に未処理の指示がある手動ループ（`ManualLoopTarget.key`）。担当者に再開を促すのに使う
    private(set) var pendingFinalInstructions: Set<String> = []
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
    /// 手動ループの epic の最終 PR への指示の確認（トークンと信用する author ごと）
    private let makeFinalInstructions: @Sendable (String, any TrustedAuthorsResolving) -> any ManualLoopFinalInstructionsChecking
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false
    /// organization の節の見出しに出すアバター画像（一覧を取り直しても画像は取り直さない）
    let avatars: OrganizationAvatarStore

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeSource: @escaping @Sendable (String) -> any LoopStatusSource = { GitHubLoopStatusSource(client: GitHubClient(token: $0)) },
        makeInboxSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) },
        organizations: @escaping () -> [String] = { OrganizationSettings.load() },
        makeTrust: @escaping @Sendable (String) -> any TrustedAuthorsResolving = { RepositoryTrustCache.trust(token: $0) },
        makeStarter: @escaping @Sendable (String) -> any LoopStarting = { GitHubLoopStarter(client: GitHubClient(token: $0)) },
        makeFinalInstructions: @escaping @Sendable (String, any TrustedAuthorsResolving) -> any ManualLoopFinalInstructionsChecking = {
            GitHubManualLoopFinalInstructions(client: GitHubClient(token: $0), trustedAuthors: $1)
        },
        avatars: OrganizationAvatarStore = OrganizationAvatarStore()
    ) {
        self.tokenStore = tokenStore
        self.avatars = avatars
        self.makeTrust = makeTrust
        self.makeStarter = makeStarter
        self.organizations = organizations
        self.makeSource = makeSource
        self.makeInboxSource = makeInboxSource
        self.makeFinalInstructions = makeFinalInstructions
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 行も「上限で待機中」「ループの開始待ち」も無い（空の表示を出す）
    var isEmpty: Bool {
        rows.isEmpty && waiting.isEmpty && usageLimited.isEmpty && manualLoops.isEmpty && buildHosts == nil
    }

    /// 全リポジトリの、直近 24 時間に別の Mac に移ったビルド（新しい順）
    func buildMoves(now: Date) -> [BuildMoveItem] {
        LoopStatusRow.buildMoves(in: rows, now: now)
    }

    /// 「手動ループ」の行
    func manualLoopItems(now: Date) -> [ManualLoopItem] {
        ManualLoopItem.items(
            epics: manualLoops,
            rows: rows,
            viewer: viewerLogin,
            needsAnswer: needsAnswer,
            pendingFinalInstructions: pendingFinalInstructions,
            now: now
        )
    }

    /// リポジトリのループをだれが回しているか
    func mode(of row: LoopStatusRow) -> LoopMode {
        row.mode(manualLoops: manualLoops)
    }

    /// リポジトリの見出しの下に並べるループ。ループが 1 つ以下なら空（今までと同じ 1 行で出す）
    func loopItems(of row: LoopStatusRow) -> [LoopStatusLoopItem] {
        row.loopItems(manualLoops: manualLoops)
    }

    /// リポジトリの節の中の行（1 要素 = `List` の 1 行）。ループが 2 つ以上のリポジトリは、見出しの直後にループの行を並べる
    func listEntries(of rows: [LoopStatusRow]) -> [LoopStatusListEntry] {
        LoopStatusListEntry.entries(of: rows, manualLoops: manualLoops)
    }

    /// 人が見るべき異常の数（タブのバッジ）。異常終了・長く動きが無い・担当 PC がいない進行中の epic・状態が途絶えた手動ループ。
    /// 同じリポジトリで複数のループが回るので、ループ（Discussion）ごとに数える
    func abnormalCount(now: Date) -> Int {
        var loops = Set<String>()
        for row in rows {
            loops.formUnion(row.abnormalLoopKeys(manualLoops: manualLoops, now: now))
        }
        for item in manualLoopItems(now: now) where item.isStale {
            // 行のキー（`loopKey`）と同じく、読んだ状態から求める（番号の無い古い形の本文の手動ループを 2 回数えない）
            loops.insert(LoopStatusRow(repository: item.epic.subject.repository, report: item.report).loopKey)
        }
        return loops.count
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

    /// 最終 PR に未処理の指示がある手動ループ。補助なので、取れなくても空として状態は出す
    private func finalInstructions(
        of epics: [ManualLoopEpic],
        rows: [LoopStatusRow],
        token: String,
        trust: any TrustedAuthorsResolving
    ) async -> Set<String> {
        let targets = ManualLoopItem.targets(epics: epics, rows: rows)
        guard !targets.isEmpty else {
            return []
        }
        return (try? await makeFinalInstructions(token, trust).loopsWithUnprocessedInstructions(targets)) ?? []
    }

    private func load() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                rows = []
                buildHosts = nil
                waiting = []
                usageLimited = []
                manualLoops = []
                pendingFinalInstructions = []
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
            async let snapshot = fetcher.status(orgs: orgs)
            async let waiting = inboxFetcher.waitingDiscussions(orgs: orgs)
            // 上限の表示は補助なので、取得に失敗してもループの状態は出す（次の更新で取り直す）
            async let usageLimited = (try? await inboxFetcher.usageLimitedRepositories(orgs: orgs, now: .now)) ?? []
            async let manualLoops = inboxFetcher.manualLoopEpics(orgs: orgs)
            // 回答待ちの判定と自分の login は補助なので、取れなくても状態は出す
            async let needsAnswer = (try? await inboxFetcher.subjectsNeedingAnswer(orgs: orgs)) ?? []
            // トークンを変えると別のアカウントになりうるので、毎回取り直す（軽い GraphQL 1 回）
            async let viewer = try? await makeStarter(token).viewerLogin()
            let fetched = try await (snapshot, waiting, usageLimited)
            let (fetchedManualLoops, fetchedNeedsAnswer, fetchedViewer) = try await (manualLoops, needsAnswer, viewer)
            // 最終 PR への指示は手動ループの状態（epic）を使って探すので、それらの後に読む
            let fetchedFinalInstructions = await finalInstructions(of: fetchedManualLoops, rows: fetched.0.rows, token: token, trust: trust)
            // 上限の取得の `try?` は打ち切りも空として返すので、打ち切られていれば途中の結果で一覧を上書きしない
            try Task.checkCancellation()
            (self.rows, self.buildHosts) = (fetched.0.rows, fetched.0.buildHosts)
            (self.waiting, self.usageLimited) = (fetched.1, fetched.2)
            self.manualLoops = fetchedManualLoops
            self.needsAnswer = Set(fetchedNeedsAnswer.map { "\($0.repository)#\($0.number)".lowercased() })
            self.viewerLogin = fetchedViewer
            self.pendingFinalInstructions = fetchedFinalInstructions
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
