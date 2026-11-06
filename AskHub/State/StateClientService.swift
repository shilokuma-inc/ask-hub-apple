import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリ（`docs/renewal/protocol.md`）の窓口。
///
/// 読むのは状態リポジトリだけ（各リポジトリの Discussion・PR は読まない）。人の意図は、この端末の鍵で署名して `intents/` に置く。
/// 司令塔は 30 秒ほどの間隔で意図を処理するので、送った後の取り直しでは、処理を待つ意図を送った結果として先に出す
final class StateClientService: ClientService {
    /// 司令塔が意図を見る間隔に合わせる。変わっていないファイルは ETag で読むので、GitHub の上限に数えられない
    let refreshInterval: Duration = .seconds(30)

    private let store: any StateStore
    private let key: DeviceSigningKey
    private let now: @Sendable () -> Date
    private var index = StateIndex()

    init(store: any StateStore, key: DeviceSigningKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.key = key
        self.now = now
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        let documents: StateDocuments
        do {
            documents = try await StateReader(store: store, device: key.keyID).read()
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        }
        let built = StateSnapshotBuilder(documents: documents, now: now()).build()
        index = built.index
        return built.snapshot
    }

    func perform(_ intent: HumanIntent) async throws {
        let draft = try StateIntentMapper(index: index).draft(for: intent)
        do {
            try await IntentSender(store: store, key: key, now: now).send(draft)
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        }
    }

    func supports(_ intent: HumanIntent) -> Bool {
        StateIntentMapper.supports(intent)
    }
}

/// 状態リポジトリの読み書きの失敗を、画面に出す文にする。トークンの値やパスの中身は入れない
enum StateServiceError {
    static func message(for error: StateStoreError) -> String {
        switch error {
        case .unauthorized:
            "GitHub のトークンが無効か、期限が切れています。設定で入れ直してください"

        case .tokenUnavailable:
            "GitHub のトークンがありません。設定で入れてください"

        case .forbidden, .notFound:
            "状態リポジトリを読めません。トークンが状態リポジトリの Contents を読み書きできるか確かめてください"

        case .rateLimited(let retryAfter), .budgetExhausted(let retryAfter):
            "GitHub の上限に達しました。\(Int(retryAfter.components.seconds)) 秒ほど待ってからやり直してください"

        case .serverError:
            "GitHub が応答しません。しばらくしてからやり直してください"

        case .transport:
            "通信できませんでした。ネットワークを確かめてください"

        case .conflict:
            "ほかの書き込みとぶつかりました。もう一度送ってください"

        case .redirected:
            "状態リポジトリが移されたか、名前が変わっています。設定で確かめてください"

        case .wrongKind, .invalidPath, .unexpected, .cancelled:
            "状態リポジトリを読み書きできませんでした"
        }
    }

    static func message(for error: ClientError) -> String {
        switch error {
        case .store(let error):
            message(for: error)

        case .signing:
            "この端末の鍵で署名できませんでした。端末のロックを解除してからやり直してください"

        case .ledger, .malformed:
            "送る形を作れませんでした"
        }
    }
}
