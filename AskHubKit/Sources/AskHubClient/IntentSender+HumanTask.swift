import AskHubProtocol
import Foundation

/// 人がする作業を終えた意図と、Secrets の公開鍵を読ませる意図
extension IntentDraft {
    /// 人がする作業を終えた（`file` の作業は、渡すファイルの参照を付け、中身は `IntentSender.send(_:attachments:)` で送る）
    public static func humanTaskDone(_ target: HumanTaskTarget, file: RequestAttachment? = nil) -> Self {
        humanTaskDone(target, payload: file.map { ["attachments": .array([$0.jsonValue])] } ?? [:])
    }

    /// GitHub の Secrets に入れる作業を、暗号文を渡して終える。`secret` は値を `SealedBox` で暗号化したもの（平文は渡さない）
    public static func humanTaskDone(_ target: HumanTaskTarget, secret: EncryptedSecret) -> Self {
        humanTaskDone(target, payload: ["secret": secret.jsonValue])
    }

    private static func humanTaskDone(_ target: HumanTaskTarget, payload: [String: JSONValue]) -> Self {
        Self(
            kind: HumanTaskDoneIntent.kind,
            repo: target.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: payload
        )
    }

    /// リポジトリの Secrets の公開鍵を、司令塔に読ませる（管理用のトークンで読み、repo.json に書く）
    public static func readSecretsKey(_ repo: RepositoryFullName) -> Self {
        Self(kind: ReadSecretsKeyIntent.kind, repo: repo)
    }
}
