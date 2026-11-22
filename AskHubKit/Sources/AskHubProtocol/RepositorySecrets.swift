import Foundation

/// GitHub の Secrets に入れる値の暗号文（人がする作業の `secret`。`humanTaskDone` の payload の `secret`）。
/// クライアントがリポジトリの公開鍵で暗号化したもので、平文は含まない（`docs/renewal/security.md` の「管理用のトークン」）
public struct EncryptedSecret: Codable, Hashable, Sendable {
    /// GitHub の Secrets の値の上限（48 KB）
    public static let maximumValueLength = 48 * 1024
    /// sealed box が値より長くなる分（使い捨ての公開鍵 32 バイトとタグ 16 バイト）
    public static let overhead = 48

    /// 暗号化に使った公開鍵の id（GitHub の `key_id`）
    public var keyId: String
    /// sealed box の暗号文（base64）
    public var encryptedValue: String

    public init(keyId: String, encryptedValue: String) {
        self.keyId = keyId
        self.encryptedValue = encryptedValue
    }

    /// payload の `secret` の値
    public var jsonValue: JSONValue {
        .object(["keyId": .string(keyId), "encryptedValue": .string(encryptedValue)])
    }

    /// 決まりに合わないところ。合っていれば nil
    public var problem: String? {
        guard SecretsPublicKey.isKeyId(keyId) else { return "secret.keyId の形が違う" }
        guard let data = Data(base64Encoded: encryptedValue), data.base64EncodedString() == encryptedValue,
              (Self.overhead + 1...Self.overhead + Self.maximumValueLength).contains(data.count) else {
            return "secret.encryptedValue は base64 の暗号文（値は 1 バイトから \(Self.maximumValueLength) バイト）"
        }
        return nil
    }
}

/// リポジトリの GitHub Actions の Secrets の公開鍵（`repo.json` の `secretsKey`）。司令塔が、人の意図（`readSecretsKey`）を処理するときに
/// 管理用のトークンで読んで書く。クライアントは、これで Secrets に入れる値を暗号化する（クライアントのトークンは状態リポジトリしか読めないため）
public struct SecretsPublicKey: Codable, Hashable, Sendable {
    /// GitHub の `key_id`
    public var keyId: String
    /// X25519 の公開鍵（base64 で 32 バイト）
    public var key: String
    public var readAt: Timestamp

    public init(keyId: String, key: String, readAt: Timestamp) {
        self.keyId = keyId
        self.key = key
        self.readAt = readAt
    }

    /// 公開鍵のバイト列（32 バイト）。形が違えば nil
    public var keyData: Data? {
        guard let data = Data(base64Encoded: key), data.count == 32 else { return nil }
        return data
    }

    var problems: [String] {
        var problems: [String] = []
        if !Self.isKeyId(keyId) { problems.append("secretsKey.keyId の形が違う") }
        if keyData == nil { problems.append("secretsKey.key は base64 の 32 バイト") }
        return problems
    }

    /// GitHub の `key_id`（英数字。100 文字まで）
    public static func isKeyId(_ id: String) -> Bool {
        (1...100).contains(id.count) && id.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && scalar.properties.isAlphabetic) || ("0"..."9").contains(scalar)
        }
    }
}

/// リポジトリの Secrets の公開鍵を読ませる人の意図（`readSecretsKey`）。封筒の `repo` が対象のリポジトリ。`target`・`targetVersion`・payload の欄は持たない。
/// 司令塔が管理用のトークンで読み、`repo.json` の `secretsKey` に書く
public struct ReadSecretsKeyIntent: Equatable, Sendable {
    public static let kind = "readSecretsKey"

    public var repo: RepositoryFullName
    public var intent: IntentReference

    public init(repo: RepositoryFullName, intent: IntentReference) {
        self.repo = repo
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が readSecretsKey でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "公開鍵を読む意図に target か targetVersion がある") }
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(repo: repo, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { [:] }
}
