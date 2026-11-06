import AskHubProtocol
import Foundation

/// 司令塔とワーカーが持つ、信用する公開鍵の一覧（`docs/renewal/protocol.md` の「公開鍵の記録」）。
///
/// - セットアップのときに、最初の鍵の id を手で固定する（`pin`）。固定した後は、別の鍵で上書きしない
/// - 確かめた一覧は Keychain に置き、状態リポジトリの記録は「新しい記録があるか」を見るためだけに使う
/// - 一覧は、前に確かめた記録の続きであるときだけ更新する。記録が短くなった・途中が差し替えられた（取り消しの記録を消して
///   鍵を戻すなど）ときは、一覧を変えずに知らせる
public struct TrustAnchor: Sendable {
    public enum Refresh: Equatable, Sendable {
        /// 新しい記録を確かめて、一覧を更新した。`added` は新しく確かめた記録の数（0 なら変わらない）
        case updated(added: Int)
        /// 前に確かめた記録より短い・途中が違う。一覧を変えない
        case rollback
        /// 新しい記録の途中に合わないものがあった。合う所までで一覧を更新した
        case problem(KeyLedger.Problem, added: Int)
    }

    public enum Failure: Error, Equatable, Sendable {
        case store(SecretStoreError)
        /// 最初の鍵を固定していない
        case notPinned
        /// すでに別の鍵を固定している
        case pinnedToAnotherKey
        /// Keychain に置いた一覧の形が違う
        case malformedCache
    }

    public let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    /// 最初の鍵を固定する。同じ鍵ならそのまま、別の鍵が固定済みなら断る
    public func pin(firstKey: KeyID) throws(Failure) {
        if let pinned = try self.firstKey() {
            guard pinned == firstKey else { throw .pinnedToAnotherKey }
            return
        }
        try write(Data(firstKey.rawValue.utf8), for: .firstKeyID)
    }

    public func firstKey() throws(Failure) -> KeyID? {
        guard let data = try read(.firstKeyID) else { return nil }
        guard let text = String(bytes: data, encoding: .utf8), let key = KeyID(rawValue: text) else { throw .malformedCache }
        return key
    }

    /// 確かめた鍵の一覧（`IntentVerifier` に渡す）
    public func trustedKeys() throws(Failure) -> [KeyID: KeyLedger.RegisteredKey] {
        try cache()?.registeredKeys() ?? [:]
    }

    /// 状態リポジトリの `keys/` を読んだ値で、一覧を更新する。`accounts` は鍵を結びつけてよいアカウント
    public func refresh(records: [JSONValue], accounts: Set<String>) throws(Failure) -> Refresh {
        guard let firstKey = try firstKey() else { throw .notPinned }
        let result = KeyLedger.verify(records, firstKey: firstKey, accounts: accounts)
        let previous = try cache()
        let known = previous?.count ?? 0
        if let previous {
            // 前に確かめた最後の記録が、今も同じ値で残っているか
            let last = records.first { $0["seq"]?.integerValue == Int64(previous.count) }
            guard result.verifiedCount >= previous.count, last.map(KeyLedger.hash) == previous.lastHash else { return .rollback }
        }
        let added = result.verifiedCount - known
        if added > 0, let last = records.first(where: { $0["seq"]?.integerValue == Int64(result.verifiedCount) }) {
            try save(Cache(count: result.verifiedCount, lastHash: KeyLedger.hash(of: last), keys: result.keys))
        }
        return result.problem.map { .problem($0, added: added) } ?? .updated(added: added)
    }

    // MARK: - Keychain に置く形

    private struct Cache: Codable {
        let count: Int
        let lastHash: String
        let keys: [TrustedKeyEntry]

        init(count: Int, lastHash: String, keys: [KeyID: KeyLedger.RegisteredKey]) {
            self.count = count
            self.lastHash = lastHash
            self.keys = keys.values
                .map(TrustedKeyEntry.init)
                .sorted { $0.keyId.rawValue < $1.keyId.rawValue }
        }

        func registeredKeys() throws(Failure) -> [KeyID: KeyLedger.RegisteredKey] {
            var keys: [KeyID: KeyLedger.RegisteredKey] = [:]
            for entry in self.keys {
                guard let der = Base64URL.decode(entry.publicKey) else { throw .malformedCache }
                keys[entry.keyId] = KeyLedger.RegisteredKey(
                    keyId: entry.keyId, publicKeyDER: der, account: entry.account, label: entry.label, addedAt: entry.addedAt
                )
            }
            return keys
        }
    }

    private func cache() throws(Failure) -> Cache? {
        guard let data = try read(.trustedKeys) else { return nil }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else { throw .malformedCache }
        return cache
    }

    private func save(_ cache: Cache) throws(Failure) {
        guard let data = try? JSONEncoder().encode(cache) else { throw .malformedCache }
        try write(data, for: .trustedKeys)
    }

    private func read(_ item: SecretItem) throws(Failure) -> Data? {
        do {
            return try store.read(item)
        } catch {
            throw .store(error)
        }
    }

    private func write(_ data: Data, for item: SecretItem) throws(Failure) {
        do {
            try store.write(data, for: item)
        } catch {
            throw .store(error)
        }
    }
}

/// Keychain に置く、確かめた鍵の 1 つ
private struct TrustedKeyEntry: Codable {
    let keyId: KeyID
    let publicKey: String
    let account: String
    let label: String
    let addedAt: Timestamp

    init(_ key: KeyLedger.RegisteredKey) {
        keyId = key.keyId
        publicKey = Base64URL.encode(key.publicKeyDER)
        account = key.account
        label = key.label
        addedAt = key.addedAt
    }
}
