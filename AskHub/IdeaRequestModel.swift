import AskHubKit
import Foundation
import Observation

/// 「新しい依頼」画面の入力・リポジトリの一覧・送信の状態
@MainActor
@Observable
final class IdeaRequestModel {
    enum RepositoriesState: Equatable {
        case idle
        case loading
        case loaded
        /// トークンが保存されていない
        case needsToken
        case failed(String)
    }

    private(set) var repositories: [RequestRepository] = []

    /// Picker に出すまとまり（担当 PC の有無と owner の組）。候補は絞らない
    func repositorySections(now: Date) -> [RepositorySection] {
        RepositorySection.grouping(repositories, now: now)
    }
    private(set) var repositoriesState = RepositoriesState.idle
    /// 直前に依頼先の一覧の取得を始めた時刻。定期の取り直し（`reloadRepositoriesIfStale`）の間隔の判断に使う
    private(set) var repositoriesLastLoaded: Date?
    /// 選んだリポジトリ（`owner/repo`）
    var repository: String?
    var summary = ""
    var body = ""
    /// 依頼に添付するファイル（選んだ順）。送るまで GitHub に上げず、メモリにだけ持つ（ファイルの URL は保存しない）
    var attachments: [AttachmentFile] = []
    private(set) var isSending = false
    /// この画面で送った依頼（新しい順）。メモリにだけ持ち、保存しない。アプリを終了するかモデルを作り直すと消える
    private(set) var sent: [SentRequest]
    private(set) var errorMessage: String?
    /// この画面で送った、担当リポジトリの作成・削除の依頼（新しい順）。`sent` と同じくメモリにだけ持つ
    private(set) var sentRepositoryRequests: [SentRepositoryRequest] = []
    private(set) var isSendingRepositoryRequest = false
    private(set) var repositoryRequestError: String?

    /// 「リリース準備」の状態。依頼先の一覧はこのモデルのものを使う。デモモードの切り替えでこのモデルと一緒に差し替わる
    let release: ReleaseRequestModel

    // 実機確認の「問題あり」（`VerifyProblemModel`）も同じトークン・依頼の作り方を使う
    let tokenStore: any TokenStore
    let makeRequester: @Sendable (String) -> any IdeaRequesting
    /// 実機確認の「問題あり」のコメントの投稿先（トークンごと）
    let makeProblemCommenter: @Sendable (String) -> any VerifyProblemCommenting
    /// 添付を上げる先（トークンごと）
    let makeUploader: @Sendable (String) -> any AttachmentUploading
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeRequester: @escaping @Sendable (String) -> any IdeaRequesting = { GitHubIdeaRequester(client: GitHubClient(token: $0)) },
        makeProblemCommenter: @escaping @Sendable (String) -> any VerifyProblemCommenting = {
            GitHubVerifyProblemCommenter(client: GitHubClient(token: $0))
        },
        makeUploader: @escaping @Sendable (String) -> any AttachmentUploading = {
            GitHubAttachmentUploader(client: GitHubClient(token: $0))
        },
        sent: [SentRequest] = [],
        organizations: @escaping () -> [String] = { OrganizationSettings.load() },
        release: ReleaseRequestModel? = nil
    ) {
        self.tokenStore = tokenStore
        self.release = release ?? ReleaseRequestModel(tokenStore: tokenStore)
        self.organizations = organizations
        self.makeRequester = makeRequester
        self.makeProblemCommenter = makeProblemCommenter
        self.makeUploader = makeUploader
        self.sent = sent
    }

    var request: IdeaRequest {
        IdeaRequest(repository: repository ?? "", summary: summary, body: body)
    }

    var canSend: Bool {
        !isSending && request.isValid
    }

    /// 取得中に `loadRepositories()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsReloadAfterLoading = false

    /// 依頼先に選べるリポジトリを取り直す。
    /// 取得中に呼ばれた場合は、その取得が終わってから取り直す（設定でトークンを変えた直後など）
    func loadRepositories() async {
        guard repositoriesState != .loading else {
            needsReloadAfterLoading = true
            return
        }
        repeat {
            needsReloadAfterLoading = false
            await loadRepositoriesOnce()
        } while needsReloadAfterLoading
    }

    /// 定期の取り直し。取得済みか前回失敗したときだけ、直前の取得から間もなければ飛ばして取り直す。
    /// まだ一度も取得していない（画面を開いたときに取得する）・取得中・トークンが無いときは何もしない。
    /// macOS で複数のウィンドウから同時に呼ばれても、取得は重ねない
    func reloadRepositoriesIfStale(now: Date = .now) async {
        switch repositoriesState {
        case .loaded, .failed:
            guard AutoRefresh.isStale(lastRefreshed: repositoriesLastLoaded, now: now) else {
                return
            }
            await loadRepositories()

        case .idle, .loading, .needsToken:
            break
        }
    }

    private func loadRepositoriesOnce() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                repositories = []
                repositoriesState = .needsToken
                return
            }
            token = saved
        } catch {
            repositoriesState = .failed(Self.message(for: error))
            return
        }
        repositoriesLastLoaded = .now
        repositoriesState = .loading
        do {
            repositories = try await makeRequester(token).repositories(in: organizations())
            // 選んでいたリポジトリが一覧から消えていたら、選び直してもらう
            if let repository, !repositories.contains(where: { $0.fullName == repository }) {
                self.repository = nil
            }
            repositoriesState = .loaded
        } catch {
            repositoriesState = .failed(Self.message(for: error))
        }
    }

    /// 依頼の Issue を作る。添付があれば、先にすべて依頼先へ上げてから、添付欄を付けた本文で作る。
    /// 上げられなければ Issue を作らず、選んだ添付は残す（再送すると上げ直す）。
    /// 成功したら要約・依頼文・添付を空にする（リポジトリは続けて依頼できるよう残す）
    func send() async {
        guard canSend else {
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            guard let token = try tokenStore.load() else {
                throw MissingTokenError()
            }
            // 送信中に Picker や入力が変わっても、送った時点の値で表示する
            var request = request
            let files = attachments
            if !files.isEmpty {
                request.attachments = try await makeUploader(token).upload(files, to: request.repository)
            }
            let issue = try await makeRequester(token).create(request)
            sent.insert(SentRequest(request: request, issue: issue), at: 0)
            summary = ""
            body = ""
            attachments = []
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// 新しいアプリのリポジトリを作る organization の候補（設定の「取得する organization」）
    var organizationChoices: [String] {
        organizations()
    }

    /// 作成を任せられる担当リポジトリ（担当 PC がいるもの）。そのリポジトリの担当 PC が作成し、担当に加える
    func assignedRepositories(now: Date) -> [String] {
        repositories.filter { $0.isAssigned(now: now) }.map(\.fullName)
    }

    /// 作成を任せる PC の Picker に出すまとまり。候補は担当 PC のいるものだけなので、owner だけで分ける（Discussion #572 Q4）
    func assignedRepositorySections(now: Date) -> [RepositorySection] {
        RepositorySection.byOwner(assignedRepositories(now: now))
    }

    /// 担当リポジトリの作成・削除の依頼（`repo-request` の Issue）を `repository` に作る。送れたら送った依頼を返す
    @discardableResult
    func send(_ request: RepositoryRequest, to repository: String) async -> SentRepositoryRequest? {
        guard !isSendingRepositoryRequest else {
            return nil
        }
        guard request.isValid, RepositoryName.isValidFullName(repository) else {
            repositoryRequestError = "依頼先を選び、各項目を正しい形式で入力してください"
            return nil
        }
        isSendingRepositoryRequest = true
        repositoryRequestError = nil
        defer { isSendingRepositoryRequest = false }
        do {
            guard let token = try tokenStore.load() else {
                throw MissingTokenError()
            }
            let issue = try await makeRequester(token).create(request, in: repository)
            let sent = SentRepositoryRequest(request: request, repository: repository, issue: issue)
            sentRepositoryRequests.insert(sent, at: 0)
            return sent
        } catch {
            repositoryRequestError = Self.message(for: error)
            return nil
        }
    }

    /// 依頼を送るときのトークンが無い
    struct MissingTokenError: Error {}

    /// 失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        switch error {
        case is MissingTokenError:
            "トークンが未設定です。設定で保存してください"

        case IdeaRequestError.invalidRequest:
            "リポジトリを選び、要約（1 行）と依頼文を入力してください"

        case is KeychainError:
            "Keychain からトークンを読み込めませんでした"

        // 依頼先に書き込めないトークン。依頼の Issue は作っていない
        case AttachmentUploadError.missingContentsPermission:
            "添付を上げられませんでした。トークンに、依頼先のリポジトリの Contents の書き込み権限（Read and write）があるか確かめてください"

        case AttachmentUploadError.conflict:
            "添付を上げられませんでした。少し待ってから、もう一度送ってください"

        default:
            InboxModel.message(for: error)
        }
    }
}
