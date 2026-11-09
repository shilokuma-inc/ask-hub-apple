import CryptoKit
import Foundation

/// 登録済みの公開鍵の一覧を、追記だけの記録の列（`keys/<seq>.json`）から確かめて作る（`docs/renewal/protocol.md` の「公開鍵の記録」）。
///
/// - 署名するのは、記録から `sig` を除いた値を RFC 8785 でそろえた UTF-8 のバイト列（人の意図の封筒と同じ方式）
/// - `previousSha256` は、`sig` を含む前の記録全体をそろえたバイト列の SHA-256（16 進の小文字）。途中の書き換え・抜けを見つける
/// - 最初の記録（`seq` 1）は、最初の鍵が自分で署名する。司令塔とワーカーは、その鍵の id をセットアップのときに手で固定する
/// - 2 つ目からは、その時点で登録済みで取り消されていない鍵が署名する
/// - 合わない記録があれば、その記録から後ろを使わない（それより前で確かめた一覧と、問題を返す）
public enum KeyLedger {
    public enum Action: String, Codable, Sendable {
        case add
        case revoke
    }

    /// 1 つの記録（`sig` を除く）
    public struct Record: Codable, Equatable, Sendable {
        public var seq: Int
        public var action: Action
        public var keyId: KeyID
        /// SubjectPublicKeyInfo の DER の base64url。`add` のときだけ
        public var publicKey: String?
        /// 鍵を結びつける GitHub のアカウント。`add` のときだけ
        public var account: String?
        /// 端末の名前（「iPhone」など）。`add` のときだけ
        public var label: String?
        public var issuedAt: Timestamp
        /// 前の記録のハッシュ。`seq` 1 では無い
        public var previousSha256: String?
        public var signedBy: KeyID

        public init(
            seq: Int,
            action: Action,
            keyId: KeyID,
            publicKey: String? = nil,
            account: String? = nil,
            label: String? = nil,
            issuedAt: Timestamp,
            previousSha256: String? = nil,
            signedBy: KeyID
        ) {
            self.seq = seq
            self.action = action
            self.keyId = keyId
            self.publicKey = publicKey
            self.account = account
            self.label = label
            self.issuedAt = issuedAt
            self.previousSha256 = previousSha256
            self.signedBy = signedBy
        }

        /// 署名する値（`v` を含み、`sig` を含まない）
        public func unsignedValue() throws -> JSONValue {
            guard case var .object(object) = try JSONValue(parsing: JSONEncoder().encode(self)) else {
                throw Problem.malformed(seq: seq)
            }
            object["v"] = .integer(Int64(KeyLedger.formatVersion))
            return .object(object)
        }
    }

    /// 確かめた鍵
    public struct RegisteredKey: Equatable, Sendable {
        public var keyId: KeyID
        public var publicKeyDER: Data
        public var account: String
        public var label: String
        public var addedAt: Timestamp

        public init(keyId: KeyID, publicKeyDER: Data, account: String, label: String, addedAt: Timestamp) {
            self.keyId = keyId
            self.publicKeyDER = publicKeyDER
            self.account = account
            self.label = label
            self.addedAt = addedAt
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        /// 記録の形が違う・知らない版
        case malformed(seq: Int?)
        /// `seq` が 1 からの連番でない（抜け）
        case outOfSequence(expected: Int, found: Int?)
        /// 同じ `seq` の記録が 2 つ以上ある。どちらが正しいか決められないので、その手前までを使う
        case duplicateSequence(seq: Int)
        /// 最初の記録が、固定した最初の鍵の自分で署名した追加でない
        case firstKeyNotPinned
        /// `keyId` が公開鍵から求めた id と違う
        case keyIdMismatch(seq: Int)
        /// 署名した鍵が、その時点で登録済みでない（取り消された鍵を含む）
        case unknownSigner(seq: Int)
        case badSignature(seq: Int)
        /// 前の記録とつながらない
        case brokenLink(seq: Int)
        /// 登録済みの鍵をもう一度足そうとした
        case alreadyRegistered(seq: Int)
        /// 登録されていない鍵を取り消そうとした
        case notRegistered(seq: Int)
        /// 最後の鍵を取り消そうとした（人の意図を出せなくなる）
        case lastKeyRevoked(seq: Int)
        /// 鍵を結びつけるアカウントが、信用するアカウントでない
        case untrustedAccount(seq: Int)
    }

    public struct Result: Equatable, Sendable {
        /// 確かめた記録までで、登録済みで取り消されていない鍵
        public var keys: [KeyID: RegisteredKey]
        /// 確かめられた記録の数
        public var verifiedCount: Int
        /// 合わなかった記録。nil ならすべて確かめられた
        public var problem: Problem?
    }

    /// 記録の形の版
    public static let formatVersion = 1

    /// `records` は `keys/` のファイルを読んだ値（並びは問わない）。`firstKey` はセットアップで固定した最初の鍵の id。
    /// `accounts` は鍵を結びつけてよい GitHub のアカウント（共同開発者を足すまでは 1 つ）
    public static func verify(_ records: [JSONValue], firstKey: KeyID, accounts: Set<String>) -> Result {
        let seqs = records.compactMap { $0["seq"]?.integerValue }
        let duplicated = Dictionary(grouping: seqs, by: { $0 }).filter { $0.value.count > 1 }.keys.min()
        let sorted = records
            .filter { record in duplicated.map { (record["seq"]?.integerValue ?? .max) < $0 } ?? true }
            .sorted { ($0["seq"]?.integerValue ?? .max) < ($1["seq"]?.integerValue ?? .max) }
        var walker = Walker(firstKey: firstKey, accounts: accounts)
        for (index, value) in sorted.enumerated() {
            do {
                try walker.apply(value, expectedSeq: index + 1)
            } catch let problem as Problem {
                return Result(keys: walker.keys, verifiedCount: index, problem: problem)
            } catch {
                return Result(keys: walker.keys, verifiedCount: index, problem: .malformed(seq: value["seq"]?.integerValue.map(Int.init)))
            }
        }
        return Result(keys: walker.keys, verifiedCount: sorted.count, problem: duplicated.map { .duplicateSequence(seq: Int($0)) })
    }

    /// `previousSha256` に入れる、記録全体（`sig` を含む）のハッシュ
    public static func hash(of record: JSONValue) -> String {
        SHA256.hash(data: CanonicalJSON.data(for: record)).map { String(format: "%02x", $0) }.joined()
    }

    /// 記録に署名して、`sig` を足した値を返す
    public static func sign(_ record: Record, using signer: (Data) throws -> P256.Signing.ECDSASignature) throws -> JSONValue {
        let unsigned = try record.unsignedValue()
        let signature = try IntentSignature.sign(envelope: unsigned, using: signer)
        guard case var .object(object) = unsigned else { throw Problem.malformed(seq: record.seq) }
        object["sig"] = .string(signature)
        return .object(object)
    }

    // MARK: -

    /// 記録を seq の順に 1 つずつ当てていく
    private struct Walker {
        let firstKey: KeyID
        let accounts: Set<String>
        var keys: [KeyID: RegisteredKey] = [:]
        var previous: JSONValue?

        mutating func apply(_ value: JSONValue, expectedSeq: Int) throws {
            let parsed = try KeyLedger.parse(value)
            let record = parsed.record
            guard record.seq == expectedSeq else { throw Problem.outOfSequence(expected: expectedSeq, found: record.seq) }
            try checkLink(record)
            let added = record.action == .add ? try KeyLedger.addedKey(record, accounts: accounts) : nil
            // 署名した鍵: 最初の記録は自分の鍵、それ以外はその時点で登録済みの鍵
            guard let signer = previous == nil ? added : keys[record.signedBy] else { throw Problem.unknownSigner(seq: record.seq) }
            let isValid = try? IntentSignature.isValid(
                signature: parsed.signature,
                envelope: parsed.unsigned,
                publicKeyDER: signer.publicKeyDER
            )
            guard isValid == true else { throw Problem.badSignature(seq: record.seq) }
            try commit(record, added: added)
            previous = value
        }

        private func checkLink(_ record: Record) throws {
            if let previous {
                guard record.previousSha256 == KeyLedger.hash(of: previous) else { throw Problem.brokenLink(seq: record.seq) }
            } else {
                guard record.previousSha256 == nil, record.action == .add, record.keyId == firstKey, record.signedBy == firstKey else {
                    throw Problem.firstKeyNotPinned
                }
            }
        }

        private mutating func commit(_ record: Record, added: RegisteredKey?) throws {
            switch record.action {
            case .add:
                guard let added, keys[added.keyId] == nil else { throw Problem.alreadyRegistered(seq: record.seq) }
                keys[added.keyId] = added
            case .revoke:
                guard keys[record.keyId] != nil else { throw Problem.notRegistered(seq: record.seq) }
                guard keys.count > 1 else { throw Problem.lastKeyRevoked(seq: record.seq) }
                keys[record.keyId] = nil
            }
        }
    }

    private struct Parsed {
        let record: Record
        /// 読んだままの値から `sig` を除いたもの（署名を確かめる相手）
        let unsigned: JSONValue
        let signature: String
    }

    private static func parse(_ value: JSONValue) throws -> Parsed {
        let seq = value["seq"]?.integerValue.map(Int.init)
        guard case var .object(object) = value, case let .string(signature)? = object.removeValue(forKey: "sig"),
              object["v"] == .integer(Int64(formatVersion)),
              let record = try? JSONDecoder().decode(Record.self, from: JSONEncoder().encode(JSONValue.object(object))) else {
            throw Problem.malformed(seq: seq)
        }
        let isAdd = record.action == .add
        // add は公開鍵・アカウント・名前を持ち、revoke は持たない
        guard isAdd == (record.publicKey != nil), isAdd == (record.account != nil), isAdd == (record.label != nil),
              record.label.map({ (1...64).contains($0.count) }) ?? true else {
            throw Problem.malformed(seq: seq)
        }
        // 署名は、読んだままの値（知らない項目も含む）から sig を除いたものに対して確かめる
        return Parsed(record: record, unsigned: .object(object), signature: signature)
    }

    private static func addedKey(_ record: Record, accounts: Set<String>) throws -> RegisteredKey {
        guard let encoded = record.publicKey, let der = Base64URL.decode(encoded),
              (try? P256.Signing.PublicKey(derRepresentation: der)) != nil,
              let account = record.account, let label = record.label else {
            throw Problem.malformed(seq: record.seq)
        }
        guard IntentSignature.keyID(publicKeyDER: der) == record.keyId else { throw Problem.keyIdMismatch(seq: record.seq) }
        guard accounts.contains(account) else { throw Problem.untrustedAccount(seq: record.seq) }
        return RegisteredKey(keyId: record.keyId, publicKeyDER: der, account: account, label: label, addedAt: record.issuedAt)
    }
}
