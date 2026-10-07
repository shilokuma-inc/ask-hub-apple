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

    /// Picker に出すまとまり（担当 PC の有無）。候補は絞らない
    func repositorySections(now: Date) -> [RepositorySection] {
        RepositorySection.grouping(repositories, now: now)
    }
    private(set) var repositoriesState = RepositoriesState.idle
    /// 選んだリポジトリ（`owner/repo`）
    var repository: String?
    var summary = ""
    var body = ""
    private(set) var isSending = false
    /// この画面で送った依頼（新しい順）。メモリにだけ持ち、保存しない。アプリを終了するかモデルを作り直すと消える
    private(set) var sent: [SentRequest]
    private(set) var errorMessage: String?

    private let tokenStore: any TokenStore
    private let makeRequester: @Sendable (String) -> any IdeaRequesting
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeRequester: @escaping @Sendable (String) -> any IdeaRequesting = { GitHubIdeaRequester(client: GitHubClient(token: $0)) },
        sent: [SentRequest] = [],
        organizations: @escaping () -> [String] = { OrganizationSettings.load() }
    ) {
        self.tokenStore = tokenStore
        self.organizations = organizations
        self.makeRequester = makeRequester
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

    /// 依頼の Issue を作る。成功したら要約と依頼文を空にする（リポジトリは続けて依頼できるよう残す）
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
            let request = request
            let issue = try await makeRequester(token).create(request)
            sent.insert(SentRequest(request: request, issue: issue), at: 0)
            summary = ""
            body = ""
        } catch {
            errorMessage = Self.message(for: error)
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

        default:
            InboxModel.message(for: error)
        }
    }
}
