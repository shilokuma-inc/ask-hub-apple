import Foundation

/// epic の最終 PR（`epic-final`）のコメントに置く目印。詳細は `docs/protocol.md` の「最終 PR への指示」を参照。
/// 人間・ループ・オーケストレーターは同じアカウントでコメントするため、author ではなくこの目印でループ・オーケストレーターのコメントを見分ける
public enum FinalPullRequestMarker {
    /// ループが最終 PR への指示に返信するときに置く目印
    public static let reply = "<!-- ask-hub:final-reply -->"
    /// オーケストレーターが最終 PR に付けるコメント（コンフリクトの解消の結果など）に置く目印。指示として扱わない
    public static let orchestrator = "<!-- ask-hub:orchestrator -->"
    /// 目印を付ける前のオーケストレーターのコメント（コンフリクトの解消の結果）の末尾。既に開いている最終 PR に残るものを指示とみなさないため
    public static let legacyOrchestratorSuffix = "（askhub-orchestrator）"
    /// CodeRabbit への依頼の書き出し（小文字で比べる）。`@coderabbitai review` などはループへの指示ではない
    public static let codeRabbitMention = "@coderabbitai"
}
