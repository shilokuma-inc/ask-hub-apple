import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// Siri・ショートカットからの依頼の窓口（Issue #1122）。アプリの「新しい依頼」と同じ依頼の意図を、この端末の鍵で署名して状態リポジトリに置く。
///
/// 送る前に、依頼先が対象のリポジトリか（外していないか）と、この端末の鍵が登録されているかを、状態リポジトリの写しで確かめる
/// （登録されていない鍵の意図は司令塔に断られ、画面の外からでは気づけないため）。テストでは状態リポジトリと鍵を差し替える
struct ShortcutRequests {
    /// 状態リポジトリと、この端末の鍵の取り方
    struct Connection {
        var store: any StateStore
        /// ロック中は Keychain を読めずに失敗する（鍵はロックの解除中だけ使える。`StateConnection.keyStore`）
        var key: () throws(DeviceSigningKey.Failure) -> DeviceSigningKey
    }

    var dataSource: () -> DataSource = { DataSource.current() }
    var connect: () throws(ShortcutRequestError) -> Connection = { () throws(ShortcutRequestError) in try Self.stateConnection() }
    var now: @Sendable () -> Date = Date.init

    /// 依頼先の候補。対象のリポジトリ（外したものを除く）を、アプリの依頼先と同じ順（持ち主ごと・名前順）で返す
    func repositories() async throws -> [RepositoryFullName] {
        let connection = try connectToState()
        let snapshot = try await Self.snapshot(of: connection.store)
        return try await Self.targets(in: snapshot)
    }

    /// 送る。依頼先の id は大文字小文字を区別せず、状態リポジトリの書き方で送る。
    /// 送れなければ `ShortcutRequestError`（Siri とショートカットのアプリに出す文言）、Siri を閉じたなどの取り消しは `CancellationError`
    func send(_ request: ShortcutRequestText, to repositoryID: String) async throws -> ShortcutRequestSent {
        guard request.body.unicodeScalars.count <= RequestIntent.maximumBodyLength else {
            throw ShortcutRequestError(message: "依頼の文は \(RequestIntent.maximumBodyLength) 文字までです")
        }
        let connection = try connectToState()
        let key: DeviceSigningKey
        do {
            key = try connection.key()
        } catch {
            throw ShortcutRequestError.locked
        }
        let snapshot = try await Self.snapshot(of: connection.store)
        guard let repo = try await Self.targets(in: snapshot).first(where: { $0.rawValue.lowercased() == repositoryID.lowercased() }) else {
            throw ShortcutRequestError(message: "\(repositoryID) は AskHub の対象のリポジトリではありません（外したか、まだ加えていません）")
        }
        switch await KeyRegistration.read(from: snapshot, device: key.keyID) {
        case .registered:
            break

        case .notRegistered:
            throw ShortcutRequestError(message: "この端末の鍵がまだ登録されていません。AskHub の設定で登録してから、もう一度依頼してください")

        case .unreadable(let message):
            throw ShortcutRequestError(message: message)
        }
        let reference: IntentReference
        do {
            reference = try await IntentSender(store: connection.store, key: key, now: now)
                .send(.request(repo: repo, title: request.summary, body: request.body))
        } catch .store(.cancelled) {
            throw CancellationError()
        } catch {
            throw ShortcutRequestError(message: StateServiceError.message(for: error))
        }
        return ShortcutRequestSent(repository: repo, summary: request.summary, epicID: RequestIntent.epicID(for: reference))
    }

    /// デモのデータでは送らない（状態リポジトリに書かない。依頼先の候補も出さない）
    private func connectToState() throws(ShortcutRequestError) -> Connection {
        guard dataSource() == .stateRepository else {
            throw ShortcutRequestError.demo
        }
        return try connect()
    }

    /// 設定のとおりの状態リポジトリと、この端末の鍵。トークンは要求のたびに Keychain から読む
    static func stateConnection() throws(ShortcutRequestError) -> Connection {
        guard let repository = StateConnection.repository() else {
            throw ShortcutRequestError(message: "状態リポジトリの名前は owner/name の形で入れてください")
        }
        return Connection(store: StateConnection.makeStore(repository: repository)) { () throws(DeviceSigningKey.Failure) in
            try StateConnection.deviceKey()
        }
    }

    /// 読むだけの写し。対象のリポジトリと公開鍵の記録を、同じ時点の中身で読む
    private static func snapshot(of store: any StateStore) async throws -> any StateStore {
        do {
            return try await store.snapshot()
        } catch {
            throw Self.failure(error)
        }
    }

    /// 対象のリポジトリ（`repos/<owner>/<repo>/repo.json`）のうち、外していないもの。形の違う `repo.json` は飛ばす
    static func targets(in store: any StateStore) async throws -> [RepositoryFullName] {
        var targets: [TargetRepository] = []
        do {
            for owner in try await directories(StatePath.repositories, in: store) {
                for name in try await directories("\(StatePath.repositories)/\(owner)", in: store) {
                    if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)"), let file = try await target(repo, in: store) {
                        targets.append(StateSnapshotBuilder.repository(file.repo))
                    }
                }
            }
        } catch {
            throw Self.failure(error)
        }
        return RepositoryOwnerGroup.grouping(targets).flatMap(\.repositories).compactMap { RepositoryFullName(rawValue: $0.fullName) }
    }

    /// 外していない対象のリポジトリの `repo.json`。無い・外した・形が違う（知らない版など）なら nil
    private static func target(_ repo: RepositoryFullName, in store: any StateStore) async throws(StateStoreError) -> RepositoryFile? {
        do {
            let file = try await StateFileStore(store: store).read(RepositoryFile.self, at: StatePath.repository(repo))?.file
            return file?.isRemoved == false ? file : nil
        } catch .store(let error) {
            throw error
        } catch {
            return nil
        }
    }

    private static func directories(_ path: String, in store: any StateStore) async throws(StateStoreError) -> [String] {
        try await store.listAll(path)?.filter { $0.kind == .directory }.map(\.name) ?? []
    }

    private static func failure(_ error: StateStoreError) -> any Error {
        error == .cancelled ? CancellationError() : ShortcutRequestError(message: StateServiceError.message(for: error))
    }
}

/// Siri・ショートカットから送った依頼
nonisolated struct ShortcutRequestSent: Equatable {
    let repository: RepositoryFullName
    let summary: String
    /// 司令塔が受け取る前から、アプリの「進行中」に出る epic の id
    let epicID: ULID

    /// Siri が読み上げ、ショートカットのアプリが出す文。例: `askhub-sandbox に「週ごとのまとめ通知」を依頼しました`
    var message: String {
        "\(repository.name) に「\(summary)」を依頼しました"
    }
}

/// Siri・ショートカットに返す失敗。トークンの値は含めない
nonisolated struct ShortcutRequestError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }

    /// 鍵を読めない（ロック中など）。ふだんは、システムがロックを解除させてから動かす（`SendRequestIntent.authenticationPolicy`）
    static let locked = Self(message: "この端末の鍵を使えませんでした。端末のロックを解除してから、もう一度依頼してください")
    static let demo = Self(message: "デモのデータを使っているため、送れません。AskHub の設定でデータを「状態リポジトリ」にしてください")
}
