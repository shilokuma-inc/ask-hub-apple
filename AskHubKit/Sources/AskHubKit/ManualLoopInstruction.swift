/// 手で回す（`manual-loop`）epic を始めるときに、Claude Code に渡す指示。
///
/// 形式はリポジトリの CLAUDE.md の「依頼の形式」の末尾に「手動で回して」を付けたもの（`.claude/ralph/README.md` の「手で回す（manual-loop）」）。
/// これを受けた Claude が、`ready-for-loop` を外し、loop-status を書き手 `manual` で書き、最終 PR を `epic-final` で作る
public enum ManualLoopInstruction {
    /// 例: `shilokuma-inc/notti-ios で epic/<機能名> のループを回したい。ゴールは Discussion #12。手動で回して（epic 名は Discussion の内容から決めて）`
    public static func make(repository: String, discussionNumber: Int) -> String {
        "\(repository) で epic/<機能名> のループを回したい。ゴールは Discussion #\(discussionNumber)。"
            + "手動で回して（epic 名は Discussion の内容から決めて）"
    }
}
