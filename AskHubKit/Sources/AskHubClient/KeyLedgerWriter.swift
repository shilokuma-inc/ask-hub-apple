import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 公開鍵の記録（`keys/<seq>.json`）に、この端末の鍵で署名した記録を足す（`docs/renewal/protocol.md` の「公開鍵の記録」）
public struct KeyLedgerWriter: Sendable {
    public var store: any StateStore
    public var key: DeviceSigningKey
    public var now: @Sendable () -> Date

    public init(store: any StateStore, key: DeviceSigningKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.key = key
        self.now = now
    }

    /// この端末の鍵を、最初の鍵（`seq` 1。自分で署名する）として登録する。記録がすでにあれば断る
    public func registerFirst(account: String, label: String) async throws(ClientError) -> Int {
        let records = try await records()
        guard records.isEmpty else { throw .ledger("公開鍵の記録がもうある（最初の鍵は登録済み）") }
        let entry = Entry(action: .add, keyID: key.keyID, publicKeyDER: key.publicKeyDER, account: account, label: label)
        return try await append(entry, after: records)
    }

    /// ほかの端末の鍵を、この端末の鍵（登録済み）の署名で登録する
    public func add(publicKeyDER: Data, account: String, label: String) async throws(ClientError) -> Int {
        let keyID = IntentSignature.keyID(publicKeyDER: publicKeyDER)
        let entry = Entry(action: .add, keyID: keyID, publicKeyDER: publicKeyDER, account: account, label: label)
        return try await append(entry, after: try await records())
    }

    /// 鍵を取り消す
    public func revoke(_ keyID: KeyID) async throws(ClientError) -> Int {
        try await append(Entry(action: .revoke, keyID: keyID, publicKeyDER: nil, account: nil, label: nil), after: try await records())
    }

    // MARK: -

    /// 足す記録の中身（`add` だけが公開鍵・アカウント・名前を持つ）
    private struct Entry {
        var action: KeyLedger.Action
        var keyID: KeyID
        var publicKeyDER: Data?
        var account: String?
        var label: String?
    }

    private func append(_ entry: Entry, after records: [JSONValue]) async throws(ClientError) -> Int {
        let seq = records.count + 1
        let record = KeyLedger.Record(
            seq: seq,
            action: entry.action,
            keyId: entry.keyID,
            publicKey: entry.publicKeyDER.map(Base64URL.encode),
            account: entry.account,
            label: entry.label,
            issuedAt: Timestamp(now()),
            previousSha256: records.last.map(KeyLedger.hash),
            signedBy: key.keyID
        )
        let signed: JSONValue
        do {
            signed = try key.sign(record)
        } catch {
            throw .signing(error)
        }
        do {
            // 版なしで作るので、ほかの端末が同じ番号を先に足していれば断られる（読み直して足し直す）
            let message = "[key] \(entry.action.rawValue) \(entry.keyID)"
            _ = try await store.write(StatePath.key(seq: seq), data: CanonicalJSON.data(for: signed), replacing: nil, message: message)
        } catch {
            throw .store(error)
        }
        return seq
    }

    /// 今の記録（番号の順）。番号が 1 から連続していなければ断る
    private func records() async throws(ClientError) -> [JSONValue] {
        var records: [(Int, JSONValue)] = []
        do {
            for entry in try await store.listAll(StatePath.keys) ?? [] where entry.kind == .file && entry.name.hasSuffix(".json") {
                guard let seq = Int(entry.name.dropLast(".json".count)), let blob = try await store.read(entry.path),
                      let record = try? JSONValue(parsing: blob.data) else {
                    throw ClientError.ledger("\(entry.path) を読めない")
                }
                records.append((seq, record))
            }
        } catch let error as ClientError {
            throw error
        } catch let error as StateStoreError {
            throw .store(error)
        } catch {
            throw .ledger("\(error)")
        }
        let sorted = records.sorted { $0.0 < $1.0 }
        guard sorted.enumerated().allSatisfy({ $0.offset + 1 == $0.element.0 }) else {
            throw .ledger("公開鍵の記録の番号が 1 から続いていない")
        }
        return sorted.map(\.1)
    }
}
