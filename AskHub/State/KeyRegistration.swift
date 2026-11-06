import AskHubProtocol
import AskHubStateStore
import Foundation

/// この端末の鍵が、公開鍵の記録（`keys/<seq>.json`）に登録されているか。
///
/// 設定の画面に出す目安で、意図を指示として扱うかどうかは、司令塔が自分で固定した最初の鍵から確かめる
enum KeyRegistration: Equatable {
    case registered(label: String)
    /// まだ登録されていない。`account` は最初の鍵のアカウント（登録のコマンドに入れる）。最初の鍵も無ければ nil
    case notRegistered(account: String?)
    case unreadable(String)

    static func read(from store: any StateStore, device: KeyID) async -> Self {
        do {
            var records: [JSONValue] = []
            for entry in try await store.listAll(StatePath.keys) ?? [] where entry.kind == .file && entry.name.hasSuffix(".json") {
                guard let blob = try await store.read(entry.path) else {
                    continue
                }
                records.append(try JSONValue(parsing: blob.data))
            }
            return check(records, device: device)
        } catch let error as StateStoreError {
            return .unreadable(StateServiceError.message(for: error))
        } catch {
            return .unreadable("公開鍵の記録の形が違います")
        }
    }

    /// 最初の記録（自分で署名した最初の鍵）を起点に、記録の列をつないで確かめる
    static func check(_ records: [JSONValue], device: KeyID) -> Self {
        guard let first = records.first(where: { $0["seq"]?.integerValue == 1 }),
              let firstKey = first["keyId"]?.stringValue.flatMap(KeyID.init(rawValue:)),
              let account = first["account"]?.stringValue else {
            return .notRegistered(account: nil)
        }
        let result = KeyLedger.verify(records, firstKey: firstKey, accounts: [account])
        if let key = result.keys[device] {
            return .registered(label: key.label)
        }
        return .notRegistered(account: account)
    }
}
