import AskHubProtocol
import Foundation

/// GitHub Actions の Secrets（人がする作業の `secret`。`docs/renewal/flows.md` の「人がする作業」）。
///
/// 管理用のトークン（Secrets の書き込み）が要る。司令塔は、署名した人の意図（`readSecretsKey`・`humanTaskDone`）を処理するときだけ呼ぶ。
/// 値はクライアントが公開鍵で暗号化した暗号文だけを受け取り、そのまま GitHub に渡す（司令塔は平文を知らない）
extension GitHubPullRequests {
    /// リポジトリの Secrets の公開鍵（`key_id` と base64 の X25519 の公開鍵）
    public func secretsPublicKey() async throws(PullRequestError) -> (keyId: String, key: String) {
        let payload = try await api.get("actions/secrets/public-key", as: SecretsKeyPayload.self)
        guard SecretsPublicKey.isKeyId(payload.keyId), Data(base64Encoded: payload.key)?.count == 32 else {
            throw .malformed("Secrets の公開鍵の形が違う")
        }
        return (payload.keyId, payload.key)
    }

    /// 暗号文を、リポジトリの Secrets の `name` に入れる（あれば置き換える）
    public func putSecret(name: String, encryptedValue: String, keyId: String) async throws(PullRequestError) {
        guard GoalFile.isSecretName(name) else { throw .invalidArgument("Secrets の名前の形が違う") }
        _ = try await api.send("PUT", api.url("actions/secrets/\(name)"), body: SecretBody(encryptedValue: encryptedValue, keyId: keyId))
    }
}

private struct SecretsKeyPayload: Decodable {
    let keyId: String
    let key: String
}

private struct SecretBody: Encodable, Sendable {
    let encryptedValue: String
    let keyId: String

    enum CodingKeys: String, CodingKey {
        case encryptedValue = "encrypted_value"
        case keyId = "key_id"
    }
}
