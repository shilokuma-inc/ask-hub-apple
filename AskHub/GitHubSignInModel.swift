import AskHubKit
import Foundation
import Observation

/// 設定画面の「GitHub でサインイン」（OAuth のデバイスフロー）の状態。
///
/// 得たトークンは `TokenStore`（Keychain）にだけ保存し、画面・ログ・URL には出さない。
@MainActor
@Observable
final class GitHubSignInModel {
    enum Phase: Equatable {
        case idle
        /// ユーザーコードを発行してもらっている
        case requesting
        /// ユーザーが `verificationURI` でコードを入力するのを待っている
        case waiting(userCode: String, verificationURI: URL)
        /// サインインしてトークンを保存した
        case signedIn
        case failed(message: String)
    }

    /// Info.plist の client ID のキー（値は `Configs/Project.xcconfig` の `GITHUB_CLIENT_ID`）
    nonisolated static let clientIDKey = "AskHubGitHubClientID"
    /// Info.plist の OAuth App のスコープのキー（`GITHUB_OAUTH_SCOPE`。GitHub App では空）
    nonisolated static let scopeKey = "AskHubGitHubOAuthScope"

    private(set) var phase: Phase = .idle

    private let flow: GitHubDeviceFlow?
    private let store: any TokenStore
    private var task: Task<Void, Never>?

    /// - Parameter flow: `nil` なら client ID が未設定で、サインインを出さない
    init(flow: GitHubDeviceFlow? = GitHubSignInModel.bundledFlow(), store: any TokenStore = KeychainTokenStore.gitHub) {
        self.flow = flow
        self.store = store
    }

    /// client ID が設定されていて、サインインを使えるか
    var isAvailable: Bool {
        flow != nil
    }

    /// サインイン中（コードの発行か承認待ち）か
    var isInProgress: Bool {
        switch phase {
        case .requesting, .waiting:
            true

        case .idle, .signedIn, .failed:
            false
        }
    }

    /// サインインを始める。画面を閉じても続くよう、`Task` はモデルが持つ
    func start() {
        guard !isInProgress else {
            return
        }
        task = Task { await signIn() }
    }

    /// サインインを取りやめる
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// コードの発行からトークンの保存までを行う
    func signIn() async {
        guard let flow else {
            return
        }
        phase = .requesting
        do {
            let authorization = try await flow.start()
            try Task.checkCancellation()
            phase = .waiting(userCode: authorization.userCode, verificationURI: authorization.verificationURI)
            let token = try await flow.waitForToken(authorization)
            try Task.checkCancellation()
            try store.save(token.accessToken)
            phase = .signedIn
        } catch {
            // 取りやめたときは `cancel()` が状態を戻している。後から届いた失敗で、次のサインインの状態を上書きしない
            guard !Task.isCancelled, !(error is CancellationError) else {
                return
            }
            phase = .failed(message: Self.message(for: error))
        }
    }

    /// Info.plist の client ID から作るデバイスフロー。未設定（空・変数のまま）なら `nil`
    nonisolated static func bundledFlow(info: [String: Any]? = Bundle.main.infoDictionary) -> GitHubDeviceFlow? {
        func value(_ key: String) -> String? {
            guard let value = info?[key] as? String, !value.isEmpty, !value.contains("$(") else {
                return nil
            }
            return value
        }
        guard let clientID = value(clientIDKey) else {
            return nil
        }
        return GitHubDeviceFlow(clientID: clientID, scope: value(scopeKey))
    }

    /// エラーの説明。トークン・デバイスコードの値は含めない
    static func message(for error: any Error) -> String {
        switch error {
        case GitHubDeviceFlow.Failure.expired:
            return "コードの有効期限が切れました。もう一度サインインしてください"

        case GitHubDeviceFlow.Failure.accessDenied:
            return "GitHub での承認が取り消されました"

        case GitHubDeviceFlow.Failure.deviceFlowDisabled:
            return "GitHub のアプリの設定でデバイスフローが有効になっていません"

        case let GitHubDeviceFlow.Failure.oauth(code, _):
            return "GitHub でサインインできませんでした（\(code)）"

        case let GitHubDeviceFlow.Failure.http(status):
            return "GitHub でサインインできませんでした（HTTP \(status)）"

        case let error as KeychainError:
            return "Keychain に保存できませんでした（OSStatus \(error.status)）"

        default:
            return "GitHub でサインインできませんでした"
        }
    }
}
