import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os

/// クリエイティブアセット（プロダクトページのヘッダー・検索結果の画像）の案を進める（`docs/renewal/creative-assets.md` の「流れ」の 2〜4）。
///
/// 人が案を頼むと（`draftCreativeAssets`）、`creative.json` の今の案が `drafting` になる。見回りの外の Task で Claude に案を書かせ、
/// `rendering` にして、既定のブランチで書き出しのワークフロー（app-kit の `app-store-creative.yml`）を起動する。見回りの周で実行を読み
/// （5 分空ける）、終わったら artifact を取り込んで見本を書き、`rendered`（人が確かめる番）にする。人が直す失敗は `failed` にする。
/// 司令塔が生きている印を書くとき（10 分ごと）と、クリエイティブアセットの人の意図を受け付けたときに見回る
public actor CreativeWatch {
    nonisolated let context: CommanderContext
    /// App Store Connect（Apple のチームごとの API キー）。版の言語・アプリ名・掲載文を読む
    nonisolated let stores: [any AppStoreConnecting]
    nonisolated let sources: any ReleaseSourceReading
    nonisolated let hosting: any ReleaseHosting
    /// 書き出しのワークフローの artifact を取り出す道具
    nonisolated let artifacts: any StoreScreenshotArtifactExtracting
    /// 案を書く道具。nil なら案を書けない（頼まれた案は失敗にする）
    nonisolated let drafter: (any CreativeDrafting)?
    /// 書き出した元の画像を置くフォルダ（常時オンの Mac。ライブラリに上げるときにここから読む）。nil なら取り込めない
    nonisolated let originals: URL?
    nonisolated let log: @Sendable (String) -> Void
    /// `wake()` で起こし、まだ終わっていない見回りの数（テストで、裏で始まる見回りの終わりを待つ）
    nonisolated let pendingWakes = OSAllocatedUnfairLock(initialState: 0)

    /// 見つけたアプリと、それを読める鍵（`stores` の番号）。起動し直したら探し直す
    var apps: [RepositoryFullName: (store: Int, app: AppStoreApp)] = [:]
    /// 案を書いている・取り込んでいる案（`<owner>/<repo>/creative/<案の版>`）。見回りの外の Task の間は始めない
    var inFlight: Set<String> = []
    /// 案を書く・取り込む Task（テストで終わりを待つ）
    var tasks: [String: Task<Void, Never>] = [:]
    /// 案を最後に書こうとした・書き出しの実行を最後に読んだ時刻
    var checkedAt: [String: Date] = [:]
    /// 待てば直る失敗（上限など）の後、GitHub に送らない時刻
    var notBefore: [String: Date] = [:]
    /// ログに出した知らせ（同じものを見回りのたびに出さない）
    private var reported: Set<String> = []
    private var running = false
    /// 見回っている間に起こされた（終わったらもう一度見回る）
    private var wokenWhileRunning = false

    public init(
        context: CommanderContext,
        stores: [any AppStoreConnecting],
        sources: any ReleaseSourceReading,
        hosting: any ReleaseHosting,
        artifacts: any StoreScreenshotArtifactExtracting = UnzipArtifactExtractor(),
        drafter: (any CreativeDrafting)?,
        originals: URL?,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.stores = stores
        self.sources = sources
        self.hosting = hosting
        self.artifacts = artifacts
        self.drafter = drafter
        self.originals = originals
        self.log = log
    }

    /// 見回りを周の外で始める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await refresh() }
    }

    /// クリエイティブアセットの人の意図を受け付けたときに、生きている印を待たずに見回る。見回っている最中なら、終わった後にもう一度見回る
    nonisolated public func wake() {
        pendingWakes.withLock { $0 += 1 }
        Task {
            await wakeUp()
            pendingWakes.withLock { $0 -= 1 }
        }
    }

    private func wakeUp() async {
        if running {
            wokenWhileRunning = true
            return
        }
        await refresh()
    }

    /// 対象のリポジトリを 1 つずつ見回る。見回っているときに呼ばれたら、何もしない
    func refresh() async {
        guard !running else { return }
        running = true
        defer { running = false }
        repeat {
            wokenWhileRunning = false
            await refreshOnce()
        } while wokenWhileRunning
    }

    private func refreshOnce() async {
        let repositories: [RepositoryFullName]
        do {
            repositories = try await context.repositories()
        } catch {
            report("クリエイティブアセットを見回るリポジトリの一覧を読めない（\(error)）。次の生きている印のときにやり直す")
            return
        }
        for repo in repositories {
            guard let settings = try? await context.readable(RepositoryFile.self, at: StatePath.repository(repo)),
                  settings.platform == .apple, !settings.isRemoved else { continue }
            await advanceCreative(repo, settings: settings)
        }
    }

    /// 見回り（`wake()` が裏で始めたものも）が終わるのを待つ（テスト）
    func waitForRefresh() async {
        while running || pendingWakes.withLock({ $0 > 0 }) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// 同じ知らせは 1 回だけログに出す
    func report(_ note: String) {
        if reported.insert(note).inserted { log(note) }
    }

    /// リポジトリのアプリ。base の Bundle ID の候補を、鍵ごとに App Store Connect で探す。見つからなければ nil
    func app(of repo: RepositoryFullName, base: String) async throws -> (store: Int, app: AppStoreApp)? {
        if let found = apps[repo] { return found }
        let bundleIDs: [String]
        do {
            bundleIDs = try await sources.bundleIdentifiers(repo, base: base)
        } catch {
            throw ReleaseStepProblem("\(repo) のビルドの設定を読めない（\(error)）", needsHuman: false)
        }
        guard !bundleIDs.isEmpty else { return nil }
        for (index, store) in stores.enumerated() {
            let found = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.apps(bundleIDs: bundleIDs) }
            if let app = found.first {
                apps[repo] = (index, app)
                return (index, app)
            }
        }
        return nil
    }

    /// GitHub の操作。待てば直る失敗は待てば直る問題、人が直す失敗は人が直す問題にする
    func github<Value>(_ body: () async throws(PullRequestError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            switch error {
            case .rateLimited, .serverError, .transport, .cancelled, .malformed, .headChanged:
                throw ReleaseStepProblem("GitHub に届かない（\(error)）", needsHuman: false)
            case .unauthorized, .tokenUnavailable, .forbidden:
                throw ReleaseStepProblem("GitHub のトークンで操作できない（\(error)）", needsHuman: true)
            default:
                throw ReleaseStepProblem("GitHub に断られた（\(error)）", needsHuman: true)
            }
        }
    }

    func appStoreConnect<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }
}

extension CreativeWatch {
    /// 書き出しのワークフロー（app-kit の呼ぶ側。ファイルの名前と入力は app-kit と合わせる）
    static let creativeWorkflow = "app-store-creative.yml"
    /// 6.9 インチの撮影の artifact（前の実行の画面を使い回すときに、残っているかを確かめる）
    static let creativeScreenshotsArtifact = "screenshots-APP_IPHONE_67"
    /// 実行を読む間隔
    static let creativeRunCheckInterval: TimeInterval = 5 * 60
    /// 実行の id が分からないまま、起動を送り直すまでの時間
    static let creativeRedispatchAfter: TimeInterval = 5 * 60
    /// 起動してから打ち切るまでの時間（6.9 インチの撮影 10〜30 分と書き出し数分）
    static let creativeRunTimeout: TimeInterval = 3 * 60 * 60
    /// 待てば直る失敗で案を書けなかったとき、書き直すまでの時間
    static let creativeDraftRetryInterval: TimeInterval = 10 * 60
    /// `workflow_dispatch` の入力の大きさの上限（GitHub の決まり。すべての入力の合計）
    static let dispatchInputLimit = 65_535

    /// 今の案を進める
    func advanceCreative(_ repo: RepositoryFullName, settings: RepositoryFile) async {
        let path = StatePath.creative(repo)
        guard let file = try? await context.readable(CreativeFile.self, at: path) else { return }
        switch file.draft?.state {
        case .drafting?:
            if let draft = file.draft { startCreativeDraft(file, draft: draft, settings: settings) }
        case .rendering?:
            if let draft = file.draft { await advanceCreativeRender(file, draft: draft, settings: settings) }
        case .rendered?, .failed?, nil:
            break
        }
        // 承認した案は、案の様子と関係なくライブラリに上げておく
        await advanceCreativeLibrary(file, settings: settings)
    }

    /// クリエイティブアセットの案を書く・取り込む Task が終わるのを待つ（テスト）
    func waitForTasks() async {
        for task in tasks.values { await task.value }
    }

    static func creativeKey(_ repo: RepositoryFullName, revision: Int) -> String { "\(repo.rawValue)/creative/\(revision)" }

    static func creativeBase(_ settings: RepositoryFile) -> String {
        settings.build?.baseBranch ?? RepositoryFile.Build.defaultBaseBranch
    }

    // MARK: - 案

    /// Claude に案を書かせる（見回りの外の Task。数分かかる）。書いている間と、待てば直る失敗の後 10 分は始めない
    private func startCreativeDraft(_ file: CreativeFile, draft: CreativeFile.Draft, settings: RepositoryFile) {
        let key = Self.creativeKey(file.repo, revision: draft.revision)
        guard !inFlight.contains(key) else { return }
        if let checked = checkedAt[key], context.now().timeIntervalSince(checked) < Self.creativeDraftRetryInterval { return }
        inFlight.insert(key)
        tasks[key] = Task { await self.draftCreative(file, draft: draft, settings: settings) }
    }

    private func draftCreative(_ file: CreativeFile, draft: CreativeFile.Draft, settings: RepositoryFile) async {
        let key = Self.creativeKey(file.repo, revision: draft.revision)
        var settled = false
        defer {
            inFlight.remove(key)
            tasks[key] = nil
            if settled { wake() }
        }
        checkedAt[key] = context.now()
        let outcome: Result<CreativeProposal, ReleaseStepProblem>
        do {
            guard let drafter else {
                throw ReleaseStepProblem("クリエイティブアセットの案を書く道具が司令塔に無い", needsHuman: true)
            }
            let request = try await creativeDraftRequest(file, draft: draft, settings: settings)
            do throws(ReleaseNotesFailure) {
                outcome = .success(try await drafter.draft(request))
            } catch {
                throw ReleaseStepProblem(error.message, needsHuman: !error.retryable)
            }
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            outcome = .failure(problem)
        } catch {
            // 待つ時間は、書けなかった時から数える（書くのに十数分かかることがあるため、始めた時からではない）
            checkedAt[key] = context.now()
            report("\(file.repo) のクリエイティブアセットの案 \(draft.revision) を書けない（\(error)）。\(Int(Self.creativeDraftRetryInterval / 60)) 分後にやり直す")
            return
        }
        settled = true
        let now = context.timestamp
        let message = "\(file.repo) のクリエイティブアセットの案 \(draft.revision)"
        let saved = await updateCreativeDraft(file.repo, revision: draft.revision, message: message) { draft in
            guard draft.state == .drafting else { return false }
            switch outcome {
            case let .success(proposal):
                draft.spec = proposal.spec
                draft.reason = Self.clamp(proposal.reason, to: 2000)
                draft.draftedAt = now
                draft.problems = proposal.spec.cautions
                draft.state = .rendering
                draft.run = nil
            case let .failure(problem):
                draft.state = .failed
                draft.failure = Self.clamp(problem.message, to: 1000)
            }
            return true
        }
        if saved?.draft?.state == .rendering { log("\(file.repo) のクリエイティブアセットの案 \(draft.revision) を書いた。書き出しを起動する") }
    }

    /// 案の材料（App Store Connect の版の言語・アプリ名・掲載文と、既定のブランチの先頭）
    func creativeDraftRequest(
        _ file: CreativeFile,
        draft: CreativeFile.Draft,
        settings: RepositoryFile
    ) async throws -> CreativeDraftRequest {
        let base = Self.creativeBase(settings)
        let found = try await app(of: file.repo, base: base)
        guard let found else {
            throw ReleaseStepProblem("App Store Connect にアプリが無い（先にアプリを作る）", needsHuman: true)
        }
        let store = stores[found.store]
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: found.app.id) }
        let iOS = versions.filter { $0.platform == .iOS }
        // 配信中の版の言語（無ければ、準備している版の言語）に書く
        guard let version = iOS.first(where: { $0.state == .readyForDistribution }) ?? iOS.first else {
            throw ReleaseStepProblem("App Store Connect に iOS の版が無い（クリエイティブアセットは iOS の版の言語に置く）", needsHuman: true)
        }
        let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.localizations(of: version.id) }
        let names = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.appNames(of: found.app.id) }
        let head = try await github { () throws(PullRequestError) in try await self.hosting.branchHead(file.repo, branch: base) }
        guard let head, ReleaseFile.isCommit(head) else { throw ReleaseStepProblem("\(base) ブランチが無い", needsHuman: true) }
        let locales = localizations.filter { LocalizedText.isLocale($0.locale) }.sorted { $0.locale < $1.locale }.map { localization in
            CreativeDraftRequest.Locale(
                locale: localization.locale,
                appName: names[localization.locale] ?? found.app.name,
                listing: localization.listing
            )
        }
        guard !locales.isEmpty else { throw ReleaseStepProblem("App Store Connect の版に言語が無い", needsHuman: true) }
        return CreativeDraftRequest(
            repo: file.repo,
            appName: found.app.name,
            commit: head,
            locales: locales,
            previous: file.previous?.spec,
            comment: draft.request.comment
        )
    }
}
