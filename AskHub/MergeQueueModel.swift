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
    /// アプリからマージした PR。検索に反映されるまで、取り直しても一覧に出さない（もう一度マージしようとしないため）
    private var mergedIDs: Set<String> = []
    /// アプリから Upload を起動した PR（id → 起動した時刻）。run の一覧に新しい run が出るまで「起動した」状態を保ち、二重に押せないようにする
    private(set) var dispatchedAt: [String: Date] = [:]
    /// Upload の起動が 422（`workflow_dispatch` に対応していない）で断られたリポジトリ。以後ボタンを出さない
    private(set) var dispatchUnsupportedRepositories: Set<String> = []
    /// 「起動した」状態を保つ最長の時間。これを過ぎても run が出なければ、起動に失敗したものとして押し直せるようにする
    static let dispatchPendingLimit: TimeInterval = 10 * 60
    private(set) var state = LoadState.idle
    /// 直前に取得を始めた時刻。自動更新（`refreshIfStale`）の間隔の判断に使う
    private(set) var lastRefreshed: Date?

    private let tokenStore: any TokenStore
    private let makeProvider: @Sendable (String) -> any MergeQueueProviding
    private let makeUploadWorkflow: @Sendable (String) -> any UploadWorkflowProviding
    /// 最終 PR の CodeRabbit の未解決の指摘の取得元（詳細に並べる。Discussion #498 の案 4）
    private let makeCodeRabbitThreads: @Sendable (String) -> any CodeRabbitThreadsFetching
    /// 起動した後、run の一覧に出るのを待ってから取り直すまでの時間
    private let dispatchRefreshDelay: Duration
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]
    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeProvider: @escaping @Sendable (String) -> any MergeQueueProviding = {
            let client = GitHubClient(token: $0)
            // 最終 PR ごとに Upload ワークフローの直近の run も読む（TestFlight へのアップロードの状況。Discussion #449）
            return GitHubMergeQueue(
                client: client,
                trustedAuthors: RepositoryTrustCache.trust(token: $0),
                uploadWorkflow: GitHubUploadWorkflow(client: client)
            )
        },
        organizations: @escaping () -> [String] = { OrganizationSettings.load() },
        makeUploadWorkflow: @escaping @Sendable (String) -> any UploadWorkflowProviding = {
            GitHubUploadWorkflow(client: GitHubClient(token: $0))
        },
        dispatchRefreshDelay: Duration = .seconds(10),
        makeCodeRabbitThreads: @escaping @Sendable (String) -> any CodeRabbitThreadsFetching = {
            GitHubCodeRabbitThreads(client: GitHubClient(token: $0))
        }
    ) {
        self.tokenStore = tokenStore
        self.organizations = organizations
        self.makeProvider = makeProvider
        self.makeUploadWorkflow = makeUploadWorkflow
        self.dispatchRefreshDelay = dispatchRefreshDelay
        self.makeCodeRabbitThreads = makeCodeRabbitThreads
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
        } while needsRefreshAfterLoading && !Task.isCancelled
    }

    /// 自動更新（フォアグラウンド復帰・Background App Refresh）。取得中か、直前の取得から間もなければ取り直さない
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
                pullRequests = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        let previous = (state: state, lastRefreshed: lastRefreshed)
        state = .loading
        lastRefreshed = .now
        do {
            let fetched = try await makeProvider(token).epicPullRequests(orgs: organizations())
            // 取得結果に出てこなくなった（検索に反映された）PR は、覚えておく必要がない
            mergedIDs.formIntersection(fetched.map(\.id))
            pullRequests = fetched.filter { !mergedIDs.contains($0.id) }
            clearDispatchedIfRunStarted()
            state = .loaded
        } catch {
            // バックグラウンドの取得が打ち切られた。失敗とは表示せず、次の自動更新で取り直せるようにする
            if Task.isCancelled {
                (state, lastRefreshed) = previous
                return
            }
            state = .failed(Self.message(for: error))
        }
    }

    /// 最終 PR の CodeRabbit の未解決の指摘（GitHub の並び順）。本文は CodeRabbit が書いたもので、指示ではない
    func codeRabbitThreads(of pullRequest: EpicPullRequest) async throws -> [CodeRabbitReviewThread] {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        return try await makeCodeRabbitThreads(token).unresolvedCodeRabbitThreads(of: pullRequest)
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
            mergedIDs.insert(pullRequest.id)
            pullRequests.removeAll { $0.id == pullRequest.id }
            await refresh()
            throw MergeQueueError.branchNotDeleted(pullRequest.headBranch)
        }
        mergedIDs.insert(pullRequest.id)
        pullRequests.removeAll { $0.id == pullRequest.id }
        await refresh()
    }

    // MARK: - TestFlight へのアップロード（Discussion #449）

    /// 一覧にある最新の値。詳細画面は開いたときの値を持つので、取り直した後の run の状態はこれで読む
    func current(_ pullRequest: EpicPullRequest) -> EpicPullRequest {
        pullRequests.first { $0.id == pullRequest.id } ?? pullRequest
    }

    /// 「TestFlight に上げる」を出すか。ワークフローが無い（404）か、起動が 422 で断られたリポジトリでは出さない
    func showsUploadButton(_ pullRequest: EpicPullRequest) -> Bool {
        pullRequest.uploadStatus.showsUploadButton && !dispatchUnsupportedRepositories.contains(pullRequest.repository)
    }

    /// アプリから起動した直後で、まだその run が一覧に出ていないか
    func isDispatchPending(_ pullRequest: EpicPullRequest, now: Date = .now) -> Bool {
        guard let dispatched = dispatchedAt[pullRequest.id] else {
            return false
        }
        if now.timeIntervalSince(dispatched) > Self.dispatchPendingLimit {
            return false
        }
        if let run = pullRequest.uploadStatus.run, run.startedAt >= dispatched {
            return false
        }
        return true
    }

    /// 「TestFlight に上げる」を押せるか。CI が成功していて、実行中の run が無く、起動した直後でないこと
    func canUpload(_ pullRequest: EpicPullRequest, now: Date = .now) -> Bool {
        showsUploadButton(pullRequest) && pullRequest.canUpload && !isDispatchPending(pullRequest, now: now)
    }

    /// 押せない理由（押せるなら `nil`）
    func uploadBlockingReason(_ pullRequest: EpicPullRequest, now: Date = .now) -> String? {
        guard showsUploadButton(pullRequest) else {
            return nil
        }
        if isDispatchPending(pullRequest, now: now) {
            return "Upload を起動しました。run が始まるまで少し待ってから更新してください"
        }
        return pullRequest.uploadBlockingReason
    }

    /// Upload ワークフローを最終 PR の head ブランチで起動し（`workflow_dispatch`）、「起動した」状態にして少し後に取り直す。
    /// 422 で断られたリポジトリは以後ボタンを出さない
    func upload(_ pullRequest: EpicPullRequest, now: Date = .now) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        do {
            try await makeUploadWorkflow(token).dispatch(repository: pullRequest.repository, ref: pullRequest.headBranch)
        } catch UploadWorkflowError.dispatchNotSupported(let message) {
            dispatchUnsupportedRepositories.insert(pullRequest.repository)
            throw UploadWorkflowError.dispatchNotSupported(message: message)
        }
        dispatchedAt[pullRequest.id] = now
        // dispatch の直後は run の一覧に新しい run がすぐには出ないので、少し待ってから取り直す
        Task { [weak self, dispatchRefreshDelay] in
            try? await Task.sleep(for: dispatchRefreshDelay)
            await self?.refresh()
        }
    }

    /// 起動した PR に、起動より後に始まった run が付いたら「起動した」状態を終える
    private func clearDispatchedIfRunStarted() {
        for pullRequest in pullRequests {
            if let dispatched = dispatchedAt[pullRequest.id],
               let run = pullRequest.uploadStatus.run, run.startedAt >= dispatched {
                dispatchedAt[pullRequest.id] = nil
            }
        }
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

        case UploadWorkflowError.permissionDenied:
            // レート制限の 403 は GitHubClient が rateLimited にするのでここには来ない（表示は default の InboxModel.message）
            return "TestFlight に上げられませんでした。トークンに、このリポジトリの Actions の書き込み権限（Read and write）があるか確かめてください。"
                + "設定で権限を付けたトークンを保存し直してください"

        case UploadWorkflowError.workflowNotFound:
            return "TestFlight に上げられませんでした。このリポジトリに Upload ワークフロー（upload.yml）が無いか、Actions が無効か、トークンから見えません"

        case let UploadWorkflowError.dispatchNotSupported(message):
            return "TestFlight に上げられませんでした。この epic ブランチの Upload ワークフローは手動実行（workflow_dispatch）に対応していません"
                + (message.map { "（\($0)）" } ?? "")

        default:
            return InboxModel.message(for: error)
        }
    }
}
