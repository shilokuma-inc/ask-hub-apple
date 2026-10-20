import AskHubKit
import Foundation
import Observation

/// 「新しい依頼」の「リリース準備」（Discussion #605 の Q1・Q2）。リポジトリのリリース準備のワークフロー（`release-prepare.yml`）を
/// `develop` で起動し、その run を表示する。アプリは GitHub だけを見る（release ブランチの作成や App Store Connect の操作はワークフローが行う）
@MainActor
@Observable
final class ReleaseRequestModel {
    /// 選んだリポジトリのリリースの状態
    struct Context: Equatable {
        /// リリース準備のワークフローがあるか
        var availability: WorkflowAvailability
        /// release ブランチとタグ。ワークフローが無いときは読まない（`nil`）
        var refs: ReleaseRefs?
        /// `develop` の `MARKETING_VERSION`。読めなかったら `nil`（既定値を入れず、人に入力してもらう）
        var marketingVersion: MarketingVersion?
        /// `MARKETING_VERSION` を読めなかった理由（読めたら `nil`）
        var marketingVersionNote: String?
        /// `develop` で起動したリリース準備の直近の run（新しい順の先頭）
        var latestRun: WorkflowRun?
    }

    enum ContextState: Equatable {
        /// リポジトリを選んでいない
        case idle
        case loading
        case loaded(Context)
        case failed(String)
    }

    /// 選んだリポジトリ（`owner/repo`）。変えたら `select(_:)` で読み直す
    private(set) var repository: String?
    private(set) var contextState = ContextState.idle
    /// リリースの状態を読んでいるか（取り直しのあいだも前の状態を出したままにするので、`contextState` とは別に持つ）
    private(set) var isLoading = false
    /// 入力中のバージョン。リポジトリを選ぶと既定値（`MARKETING_VERSION` の次のマイナー）が入る
    var versionText = ""
    private(set) var isStarting = false
    /// 直前の起動の失敗（起動できたら `nil`）
    private(set) var errorMessage: String?
    /// アプリから起動したリポジトリ（→ 起動した時刻とバージョン）。run の一覧に起動より後の run が出るまで「起動した」状態を保ち、二重に押せないようにする
    private(set) var dispatched: [String: Dispatch] = [:]

    struct Dispatch: Equatable {
        /// 起動した時刻（端末の時計）。「起動した」状態を保つ最長の時間（`dispatchPendingLimit`）を数えるのに使う
        var date: Date
        var version: ReleaseVersion
        /// 起動したときに出ていた直近の run の id（まだ run が無ければ `nil`）。これより大きい id の run が出たら、起動した run とみなす
        var previousRunID: Int?
    }

    /// 「起動した」状態を保つ最長の時間。これを過ぎても run が出なければ、起動に失敗したものとして押し直せるようにする
    static let dispatchPendingLimit: TimeInterval = 10 * 60
    /// リリース準備を起動するブランチ（release ブランチを切る元）
    nonisolated static let dispatchRef = GitHubReleaseReader.developBranch

    private let tokenStore: any TokenStore
    private let makeReader: @Sendable (String) -> any ReleaseReading
    private let makeWorkflow: @Sendable (String) -> any WorkflowProviding
    /// 起動した後、run の一覧に出るのを待ってから取り直すまでの時間
    private let dispatchRefreshDelay: Duration
    /// 読み取りの世代。読み取りを始めるたびに増やし、終わったときに変わっていたら（後から始めた読み取りがある）その結果を捨てる
    private var loadGeneration = 0

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeReader: @escaping @Sendable (String) -> any ReleaseReading = { GitHubReleaseReader(client: GitHubClient(token: $0)) },
        makeWorkflow: @escaping @Sendable (String) -> any WorkflowProviding = { ReleaseWorkflow.prepare.client(GitHubClient(token: $0)) },
        dispatchRefreshDelay: Duration = .seconds(10)
    ) {
        self.tokenStore = tokenStore
        self.makeReader = makeReader
        self.makeWorkflow = makeWorkflow
        self.dispatchRefreshDelay = dispatchRefreshDelay
    }

    var context: Context? {
        if case .loaded(let context) = contextState {
            return context
        }
        return nil
    }

    /// 入力したバージョン。形（`MAJOR.MINOR.PATCH`）が違えば `nil`
    var version: ReleaseVersion? {
        ReleaseVersion(versionText.trimmingCharacters(in: .whitespaces))
    }

    /// リポジトリを選び、リリースの状態を読み直す。バージョンの欄には既定値（次のマイナー。読めなければ空）を入れる。
    /// 同じリポジトリを選び直したときは、入力中のバージョンを残して読み直す
    func select(_ repository: String?) async {
        guard repository != self.repository else {
            await refresh()
            return
        }
        self.repository = repository
        // 前のリポジトリの状態を出さない
        contextState = repository == nil ? .idle : .loading
        versionText = ""
        errorMessage = nil
        await reload(resetsVersion: true)
    }

    /// 選んでいるリポジトリの状態を読み直す。入力中のバージョンは変えない
    func refresh() async {
        await reload(resetsVersion: false)
    }

    private func reload(resetsVersion: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let repository else {
            contextState = .idle
            isLoading = false
            return
        }
        isLoading = true
        // 取り直しのあいだは前の状態を出したままにする（ボタンは押せない）
        if context == nil {
            contextState = .loading
        }
        let result: ContextState
        do {
            guard let token = try tokenStore.load() else {
                throw IdeaRequestModel.MissingTokenError()
            }
            result = .loaded(try await Self.loadContext(
                repository: repository,
                reader: makeReader(token),
                workflow: makeWorkflow(token)
            ))
        } catch {
            result = .failed(Self.message(for: error))
        }
        // 読んでいるあいだに別のリポジトリを選んだり、同じリポジトリを読み直したりしたら、古い結果は捨てる（後から始めた読み取りの結果を出す）
        guard generation == loadGeneration, repository == self.repository else {
            return
        }
        isLoading = false
        contextState = result
        if case .loaded(let context) = result {
            clearDispatchedIfRunStarted(context.latestRun)
            if resetsVersion || versionText.isEmpty {
                versionText = context.marketingVersion?.nextMinor?.description ?? ""
            }
        }
    }

    nonisolated private static func loadContext(
        repository: String,
        reader: any ReleaseReading,
        workflow: any WorkflowProviding
    ) async throws -> Context {
        let availability = try await workflow.availability(repository: repository)
        guard availability != .notFound else {
            return Context(availability: availability)
        }
        async let refs = reader.refs(repository: repository)
        async let runs = workflow.recentRuns(repository: repository, branch: dispatchRef, event: "workflow_dispatch", limit: 5)
        var context = Context(availability: availability, refs: try await refs, latestRun: try await runs.first)
        do {
            context.marketingVersion = try await reader.marketingVersion(repository: repository, ref: dispatchRef)
            if let marketingVersion = context.marketingVersion, marketingVersion.version == nil {
                context.marketingVersionNote = "develop の MARKETING_VERSION（\(marketingVersion.raw)）が MAJOR.MINOR.PATCH の形ではありません。"
                    + "バージョンを入力してください"
            }
        } catch ReleaseReadError.fileNotFound, ReleaseReadError.marketingVersionNotFound, ReleaseReadError.invalidContent {
            // 既定値が入らないだけで、準備は始められる
            context.marketingVersionNote = "develop の Configs/Project.xcconfig から MARKETING_VERSION を読めませんでした。バージョンを入力してください"
        }
        return context
    }

    // MARK: - 起動

    /// アプリから起動した直後で、まだその run が一覧に出ていないか
    func isDispatchPending(now: Date = .now) -> Bool {
        guard let repository, let dispatch = dispatched[repository] else {
            return false
        }
        return now.timeIntervalSince(dispatch.date) <= Self.dispatchPendingLimit
    }

    /// 「リリース準備を始める」を押せない理由（押せるなら `nil`）。
    /// アプリが見るのは形・すでにある release ブランチ / タグ・タグの無い別の release ブランチだけで、
    /// `MARKETING_VERSION` との大小は判定しない（ワークフローの入力の検査が正本）
    func blockingReason(now: Date = .now) -> String? {
        guard repository != nil else {
            return "リリースするリポジトリを選んでください"
        }
        guard let context else {
            return nil
        }
        switch context.availability {
        case .notFound:
            return "このリポジトリにはリリースのワークフロー（\(ReleaseWorkflow.prepare.file)）がありません"

        case .disabled(let state):
            return "このリポジトリのリリース準備のワークフローは無効にされています（\(state)）。GitHub のリポジトリの Actions で有効にしてください"

        case .active:
            break
        }
        if isDispatchPending(now: now) {
            return "リリース準備を起動しました。run が始まるまで少し待ってから更新してください"
        }
        if context.latestRun?.isRunning == true {
            return "リリース準備の run が実行中です。終わってから始めてください"
        }
        return versionBlockingReason(context.refs)
    }

    /// 入力したバージョンで始められない理由（形・すでにある release ブランチ / タグ・タグの無い別の release ブランチ）
    private func versionBlockingReason(_ refs: ReleaseRefs?) -> String? {
        guard let version else {
            return "バージョンは MAJOR.MINOR.PATCH の形（例: 1.1.0。先頭に 0 を付けない）で入力してください"
        }
        if let refs {
            if refs.isTaken(version) {
                return "\(version.branchName) のブランチか \(version.tagName) のタグがすでにあります。別のバージョンを入力してください"
            }
            if let unreleased = refs.unreleasedVersions.first {
                return "タグの無い release ブランチ（\(unreleased.branchName)）があります。そのリリースを終えてから始めてください"
            }
        }
        return nil
    }

    /// 「リリース準備を始める」を押せるか
    func canStart(now: Date = .now) -> Bool {
        !isStarting && !isLoading && context != nil && blockingReason(now: now) == nil
    }

    /// `canStart` が偽になる理由。`blockingReason` に出ないもの（読み取り中・状態を読めていない）も含める
    private func notStartableReason(now: Date) -> String? {
        if let reason = blockingReason(now: now) {
            return reason
        }
        if isLoading {
            return "リリースの状態を読み直しています。読み終わってからもう一度始めてください"
        }
        if context == nil {
            return "リリースの状態を読めていません。更新してからもう一度始めてください"
        }
        return nil
    }

    /// リリース準備のワークフローを `develop` で起動し（`workflow_dispatch`。inputs は `version`）、「起動した」状態にして少し後に取り直す
    func start(now: Date = .now) async {
        // 送っている最中に押し直されたときは、何も出さない（二重に送らない）
        guard !isStarting else {
            return
        }
        // 確認のダイアログを出したあとに状態が変わって（取り直し・run の開始など）押せなくなったら、送らなかった理由を出す
        guard canStart(now: now), let repository, let version else {
            errorMessage = "リリース準備を始めませんでした。" + (notStartableReason(now: now) ?? "")
            return
        }
        let previousRunID = context?.latestRun?.id
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            guard let token = try tokenStore.load() else {
                throw IdeaRequestModel.MissingTokenError()
            }
            try await makeWorkflow(token).dispatch(
                repository: repository,
                ref: Self.dispatchRef,
                inputs: ReleaseWorkflow.prepareInputs(version: version)
            )
        } catch {
            // 送っているあいだに別のリポジトリを選んだら、そのリポジトリの画面には出さない
            if repository == self.repository {
                errorMessage = Self.message(for: error)
            }
            return
        }
        dispatched[repository] = Dispatch(date: now, version: version, previousRunID: previousRunID)
        // dispatch は run の id を返さず、直後の一覧にはまだ出ないので、少し待ってから取り直す
        Task { [weak self, dispatchRefreshDelay] in
            try? await Task.sleep(for: dispatchRefreshDelay)
            await self?.refresh()
        }
    }

    /// 起動したときより新しい run（id が大きい）が出たら「起動した」状態を終える。
    /// run の id はリポジトリの中で増えていくので、端末の時計がずれていても見分けられる（開始時刻とは比べない）
    private func clearDispatchedIfRunStarted(_ run: WorkflowRun?) {
        guard let repository, let dispatch = dispatched[repository], let run else {
            return
        }
        if dispatch.previousRunID.map({ run.id > $0 }) ?? true {
            dispatched[repository] = nil
        }
    }

    // MARK: - 文言

    /// 失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        switch error {
        case is IdeaRequestModel.MissingTokenError:
            return "トークンが未設定です。設定で保存してください"

        case WorkflowError.permissionDenied:
            // レート制限の 403 は GitHubClient が rateLimited にするのでここには来ない
            return "リリース準備を起動できませんでした。トークンに、このリポジトリの Actions の Read and write と Contents の Read があるか確かめてください。"
                + "設定で権限を付けたトークンを保存し直してください"

        case ReleaseReadError.permissionDenied:
            return "リリースの状態を読めませんでした。トークンに、このリポジトリの Contents の Read があるか確かめてください"

        case WorkflowError.workflowNotFound, ReleaseReadError.repositoryNotFound:
            return "このリポジトリにはリリースのワークフロー（\(ReleaseWorkflow.prepare.file)）がありません（Actions が無効か、トークンから見えないときも同じです）"

        case let error as WorkflowError:
            return dispatchRejectionMessage(error)

        case let ReleaseReadError.unsupportedDraftSchema(version):
            return "最新情報の下書きの形（schemaVersion \(version)）に、このアプリは対応していません。アプリを新しくしてください"

        case let ReleaseReadError.invalidContent(path):
            return "\(path) を読めませんでした"

        default:
            return IdeaRequestModel.message(for: error)
        }
    }

    /// 起動の 422 の理由ごとの説明
    private static func dispatchRejectionMessage(_ error: WorkflowError) -> String {
        let prefix = "リリース準備を起動できませんでした。"
        switch error.dispatchRejection {
        case .workflowDisabled:
            return prefix + "リリース準備のワークフローが無効にされています。GitHub のリポジトリの Actions で有効にしてください"

        case .noWorkflowDispatchTrigger:
            return prefix + "develop の \(ReleaseWorkflow.prepare.file) に手動実行（workflow_dispatch）がありません"

        case .refNotFound:
            return prefix + "このリポジトリに develop ブランチがありません"

        case .invalidInputs:
            return prefix + "ワークフローの入力（version）が、このアプリの送るものと合いません。ワークフローかアプリを新しくしてください"
                + detail(of: error)

        case .other, nil:
            return prefix + "GitHub が受け付けませんでした" + detail(of: error)
        }
    }

    private static func detail(of error: WorkflowError) -> String {
        guard case .dispatchNotSupported(let message?) = error else {
            return ""
        }
        return "（\(message)）"
    }
}
