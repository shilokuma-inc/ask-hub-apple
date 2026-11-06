import Foundation

/// 人の意図の封筒（`docs/renewal/protocol.md` の「封筒」）
public struct IntentEnvelope: Codable, Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public var type: String
        public var epic: ULID?
        /// 対象の種類ごとの id（質問の `q1`・ジョブの ULID など）。パスに使う前に、種類ごとの形を確かめる
        public var id: String?

        public init(type: String, epic: ULID? = nil, id: String? = nil) {
            self.type = type
            self.epic = epic
            self.id = id
        }
    }

    /// 封筒の形の版（JSON では `v`）
    public var version: Int
    public var kind: String
    public var repo: RepositoryFullName?
    public var target: Target?
    public var targetVersion: String?
    public var bodySha256: String?
    public var payload: [String: JSONValue]?
    public var issuedAt: Timestamp
    /// 一度しか使えない番号。処理した記録（`consumed/<keyId>/<nonce>`）のパスに使う
    public var nonce: ULID
    public var keyId: KeyID

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind, repo, target, targetVersion, bodySha256, payload, issuedAt, nonce, keyId
    }

    public init(
        version: Int = 1,
        kind: String,
        repo: RepositoryFullName? = nil,
        target: Target? = nil,
        targetVersion: String? = nil,
        bodySha256: String? = nil,
        payload: [String: JSONValue]? = nil,
        issuedAt: Timestamp,
        nonce: ULID,
        keyId: KeyID
    ) {
        self.version = version
        self.kind = kind
        self.repo = repo
        self.target = target
        self.targetVersion = targetVersion
        self.bodySha256 = bodySha256
        self.payload = payload
        self.issuedAt = issuedAt
        self.nonce = nonce
        self.keyId = keyId
    }

    /// 署名する値（`JSONValue`）に変える
    public func jsonValue() throws -> JSONValue {
        try JSONValue(parsing: JSONEncoder().encode(self))
    }

    init(_ value: JSONValue) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}

/// 人の意図の目印から、署名・本文・時刻を確かめる。
///
/// `docs/renewal/protocol.md` の「確かめること」のうち、状態を見ずに確かめられる 1（署名）・3（本文）・6（時刻）を受け持つ。
/// 2（書き手のアカウント）・4（対象の版）・5（一度しか使えない番号）は、状態を持つ呼び出し側で確かめる。
public struct IntentVerifier: Sendable {
    public enum Rejection: Error, Equatable {
        /// 目印が人の意図でない
        case notIntent
        /// 目印の形が壊れている
        case malformed
        /// 知らない版の封筒
        case unsupportedVersion
        /// 登録されていない、または取り消された鍵
        case unknownKey
        /// 署名が合わない
        case badSignature
        /// 本文が署名したときのものと違う
        case bodyMismatch
        /// 有効期間を過ぎている
        case expired
        /// 署名の時刻が先すぎる（時計のずれの許容を超える）
        case issuedInFuture
    }

    /// 鍵の id → 公開鍵（SubjectPublicKeyInfo の DER）。登録済みで取り消されていないものだけを渡す
    public var publicKeys: [KeyID: Data]
    /// 人の意図の有効期間（決定: 7 日）
    public var maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// 時計のずれとして許す、未来の署名の時刻の幅
    public var allowedClockSkew: TimeInterval = 5 * 60

    public init(publicKeys: [KeyID: Data]) {
        self.publicKeys = publicKeys
    }

    /// 目印を読んだ結果から、人の意図を確かめて封筒を返す
    public func verify(_ marker: ProtocolMarker.Parsed, now: Date) throws(Rejection) -> IntentEnvelope {
        guard marker.value["type"]?.stringValue == "intent" else { throw .notIntent }
        guard let envelopeValue = marker.value["envelope"], let signature = marker.value["sig"]?.stringValue else {
            throw .malformed
        }
        return try verify(envelope: envelopeValue, signature: signature, body: marker.body, now: now)
    }

    /// 状態リポジトリの `intents/` に置いた人の意図（`{"envelope": …, "sig": "…"}`）を確かめる。
    /// 人が読む本文を持たないので、封筒に `bodySha256` があれば受け付けない
    public func verify(stored value: JSONValue, now: Date) throws(Rejection) -> IntentEnvelope {
        guard let envelopeValue = value["envelope"], let signature = value["sig"]?.stringValue else { throw .malformed }
        return try verify(envelope: envelopeValue, signature: signature, body: nil, now: now)
    }

    /// `body` は目印の前の本文。状態リポジトリに置いた意図では nil
    private func verify(
        envelope envelopeValue: JSONValue,
        signature: String,
        body: String?,
        now: Date
    ) throws(Rejection) -> IntentEnvelope {
        guard case .object = envelopeValue else { throw .malformed }
        // 形の合わない値（パスに使えない nonce など）を含む封筒は、署名を確かめる前に弾く
        guard let envelope = try? IntentEnvelope(envelopeValue) else { throw .malformed }
        guard envelope.version == 1 else { throw .unsupportedVersion }
        guard let publicKey = publicKeys[envelope.keyId] else { throw .unknownKey }
        // 署名は、読んだままの値（知らない項目も含む）に対して確かめる。型に読み直した値に対してではない
        guard let isValid = try? IntentSignature.isValid(signature: signature, envelope: envelopeValue, publicKeyDER: publicKey),
              isValid else {
            throw .badSignature
        }
        guard envelope.bodySha256 == body.map(ProtocolMarker.bodySHA256) else { throw .bodyMismatch }
        let issuedAt = envelope.issuedAt.date
        if issuedAt.timeIntervalSince(now) > allowedClockSkew { throw .issuedInFuture }
        if now.timeIntervalSince(issuedAt) > maximumAge { throw .expired }
        return envelope
    }
}
