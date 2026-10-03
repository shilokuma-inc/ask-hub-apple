/// AskHub のプロトコルで使う GitHub のラベル。
///
/// Discussion #1 の決定に基づく。詳細は `docs/protocol.md` を参照。
public enum AskHubLabel: String, CaseIterable, Sendable {
    /// 人間の回答を待っている質問がある Discussion / PR
    case needsAnswer = "needs-answer"
    /// Discussion の回答が確定し、ループを始めてよい
    case readyForLoop = "ready-for-loop"
}
