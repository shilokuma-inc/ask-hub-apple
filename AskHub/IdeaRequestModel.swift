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

    private(set) var repositories: [String] = []
    private(set) var repositoriesState = RepositoriesState.idle
    /// 選んだリポジトリ（`owner/repo`）
    var repository: String?
    var summary = ""
    var body = ""
    private(set) var isSending = false
    /// 直前に作った依頼の Issue
    private(set) var created: CreatedIssue?
    private(set) var errorMessage: String?

    private let tokenStore: any TokenStore
    private let makeRequester: @Sendable (String) -> any IdeaRequesting

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeRequester: @escaping @Sendable (String) -> any IdeaRequesting = { GitHubIdeaRequester(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.makeRequester = makeRequester
    }

    var request: IdeaRequest {
        IdeaRequest(repository: repository ?? "", summary: summary, body: body)
    }

    var canSend: Bool {
        !isSending && request.isValid
    }

    /// 依頼先に選べるリポジトリを取り直す
    func loadRepositories() async {
        guard repositoriesState != .loading else {
            return
        }
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
            repositories = try await makeRequester(token).repositories(in: InboxModel.org)
            // 選んでいたリポジトリが一覧から消えていたら、選び直してもらう
            if let repository, !repositories.contains(repository) {
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
            created = try await makeRequester(token).create(request)
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
