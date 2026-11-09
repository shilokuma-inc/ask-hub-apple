import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 人の意図の署名を確かめる公開鍵の一覧を、状態リポジトリの `keys/` と Keychain の最初の鍵から作る（`docs/renewal/protocol.md` の「公開鍵の記録」）。
///
/// 一覧は前に確かめた記録の続きのときだけ更新する。記録が巻き戻された・差し替えられたときは、人の意図を処理しない
public struct TrustedKeys: Sendable {
    public var anchor: TrustAnchor
    public var store: any StateStore
    /// 鍵を結びつけてよい GitHub のアカウント
    public var accounts: Set<String>
    public var log: @Sendable (String) -> Void

    public init(anchor: TrustAnchor, store: any StateStore, accounts: Set<String>, log: @escaping @Sendable (String) -> Void) {
        self.anchor = anchor
        self.store = store
        self.accounts = accounts
        self.log = log
    }

    /// `keys/` を読んで一覧を更新し、確かめた鍵で署名を確かめるものを作る
    public func verifier() async throws(CommanderError) -> IntentVerifier {
        let records = try await records()
        do {
            switch try anchor.refresh(records: records, accounts: accounts) {
            case let .updated(added):
                if added > 0 { log("公開鍵の記録を \(added) 件確かめた") }
            case let .problem(problem, added):
                // 合う所までの一覧で続ける（合わない記録の後ろの鍵は使わない）
                log("公開鍵の記録に合わないものがあった（\(problem)）。合う所まで（\(added) 件）を使う")
            case .rollback:
                throw CommanderError.untrustedKeys("公開鍵の記録が、前に確かめたものより短い・途中が違う")
            }
            return IntentVerifier(publicKeys: try anchor.trustedKeys().mapValues(\.publicKeyDER))
        } catch let error as CommanderError {
            throw error
        } catch {
            throw .untrustedKeys("\(error)")
        }
    }

    /// `keys/<seq>.json` の記録（番号の順）
    private func records() async throws(CommanderError) -> [JSONValue] {
        do {
            var records: [(Int, JSONValue)] = []
            for entry in try await store.listAll(StatePath.keys) ?? [] where entry.kind == .file && entry.name.hasSuffix(".json") {
                guard let seq = Int(entry.name.dropLast(".json".count)), let blob = try await store.read(entry.path) else { continue }
                guard let record = try? JSONValue(parsing: blob.data) else {
                    throw CommanderError.untrustedKeys("\(entry.path) を読めない")
                }
                records.append((seq, record))
            }
            return records.sorted { $0.0 < $1.0 }.map(\.1)
        } catch let error as CommanderError {
            throw error
        } catch let error as StateStoreError {
            throw .store(error)
        } catch {
            throw .untrustedKeys("\(error)")
        }
    }
}
