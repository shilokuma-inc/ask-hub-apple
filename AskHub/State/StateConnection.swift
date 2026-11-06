import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 画面に出すデータ。既定は状態リポジトリ。UI テストと撮影は、起動引数 `-demoScenario` でデモに固定する
enum DataSource: String, CaseIterable {
    case stateRepository
    case demo

    static let preferenceKey = "dataSource"

    var label: String {
        switch self {
        case .stateRepository: "状態リポジトリ"
        case .demo: "デモのデータ"
        }
    }

    /// 起動引数でデモの場面を決めたとき（UI テスト・撮影）は、設定によらずデモで動かす
    static func current(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        if ScreenshotDemo.isEnabled || arguments.contains("-\(DemoScenario.preferenceKey)") {
            return .demo
        }
        return defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .stateRepository
    }
}

/// 状態リポジトリへのつなぎ方（`docs/renewal/security.md`）。
///
/// GitHub のトークンと署名の鍵は、この端末の Keychain だけに置く。UserDefaults には、状態リポジトリの名前とデータの選択だけを置く
enum StateConnection {
    static let keychainService = "jp.shilokuma.AskHub"
    static let repositoryPreferenceKey = "stateRepository"
    static let defaultRepository = "shilokuma-inc/askhub-state"

    /// トークン。裏の取り直しでも読めるよう、起動後に一度ロックを解除すれば読める（ほかの端末に同期しない）
    static let tokenStore: any SecretStore = KeychainSecretStore(service: keychainService, accessibility: .afterFirstUnlock)
    /// 署名の鍵。端末のロックが解除されている間だけ使える（ほかの端末に同期しない）
    static let keyStore: any SecretStore = KeychainSecretStore(service: keychainService, accessibility: .whenUnlocked)

    static func repository(defaults: UserDefaults = .standard) -> RepositoryFullName? {
        RepositoryFullName(rawValue: defaults.string(forKey: repositoryPreferenceKey) ?? defaultRepository)
    }

    /// この端末の署名の鍵。無ければ作る（Secure Enclave が無い Simulator ではソフトウェアの鍵）
    static func deviceKey() throws(DeviceSigningKey.Failure) -> DeviceSigningKey {
        try DeviceSigningKey.loadOrCreate(in: keyStore)
    }

    /// 状態リポジトリの読み書き。トークンは要求のたびに Keychain から読み、ほかには持たない
    static func makeStore(repository: RepositoryFullName, tokens: any SecretStore = tokenStore) -> GitHubContentsStore {
        GitHubContentsStore(repository: repository, budget: WriteBudget(limits: .client)) {
            guard let data = try? tokens.read(.githubToken), let token = String(bytes: data, encoding: .utf8), !token.isEmpty else {
                throw StateStoreError.tokenUnavailable
            }
            return token
        }
    }

    /// 設定のとおりの窓口。作れないとき（鍵を作れない・名前の形が違う）は、その理由を取り直しのたびに出す窓口にする
    static func makeService() -> any ClientService {
        guard let repository = repository() else {
            return UnavailableClientService(message: "状態リポジトリの名前は owner/name の形で入れてください")
        }
        do {
            return StateClientService(store: makeStore(repository: repository), key: try deviceKey())
        } catch {
            return UnavailableClientService(message: "この端末の署名の鍵を用意できませんでした。端末のロックを解除してから開き直してください")
        }
    }
}

/// つなげないときの窓口。読むたびに理由を返し、画面はそれを失敗として出す
final class UnavailableClientService: ClientService {
    let refreshInterval: Duration = .seconds(30)
    let message: String

    init(message: String) {
        self.message = message
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        throw ClientServiceError(message: message)
    }

    func perform(_ intent: HumanIntent) async throws {
        throw ClientServiceError(message: message)
    }

    func supports(_ intent: HumanIntent) -> Bool {
        false
    }
}
