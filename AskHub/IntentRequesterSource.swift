import AppIntents
import AskHubKit
import Foundation

/// App Intents から GitHub に依頼するときの requester の取り方。トークンと requester の取り方はアプリの「新しい依頼」と同じ。テストでは差し替える
struct IntentRequesterSource {
    var tokenStore: any TokenStore = KeychainTokenStore.gitHub
    var makeRequester: (String) -> any IdeaRequesting = { GitHubIdeaRequester(client: GitHubClient(token: $0)) }
    /// デモモードではトークンを読まず、GitHub に接続しない
    var usesSampleData: () -> Bool = { DemoMode.usesSampleData }

    /// デモモードならサンプルの requester、そうでなければ保存したトークンの requester
    func requester() throws -> any IdeaRequesting {
        try requester(usesSampleData: usesSampleData())
    }

    /// `usesSampleData` を読み済みのとき（結果の文言にもデモモードかを使うとき）に、同じ値で requester を選ぶ
    func requester(usesSampleData: Bool) throws -> any IdeaRequesting {
        if usesSampleData {
            return SampleIdeaRequester()
        }
        guard let token = try tokenStore.load() else {
            throw IdeaRequestModel.MissingTokenError()
        }
        return makeRequester(token)
    }
}

/// Siri・ショートカットに返す失敗。文言はアプリの「新しい依頼」と同じ（`IdeaRequestModel.message(for:)`）で、トークンの値は含めない
nonisolated struct AskHubIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }

    /// Siri・ショートカットに返す形にする。キャンセル（Siri を閉じたなど）は失敗の文言にせず、そのまま返す
    @MainActor
    static func wrapping(_ error: any Error) -> any Error {
        // URLSession の async API は、タスクのキャンセルを `URLError(.cancelled)` で投げる
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return error
        }
        return Self(message: IdeaRequestModel.message(for: error))
    }
}
