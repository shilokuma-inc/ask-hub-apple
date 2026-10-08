import Foundation

/// 手動ループ（`manual-loop`）の epic を始める・再開するときに、担当者が Claude Code に渡す指示。
///
/// 受けた Claude は、リポジトリの `scripts/askhub-manual.sh` で準備・起動・状態の書き出し・最終 PR を行う
/// （手順はリポジトリの `.claude/ralph/README.md` の「手で回す（manual-loop）」）
public enum ManualLoopInstruction {
    /// 始めるときの指示。例: `shilokuma-inc/notti-ios で Discussion #12 の epic を手動ループで回して`
    public static func start(repository: String, discussionNumber: Int) -> String {
        "\(repository) で Discussion #\(discussionNumber) の epic を手動ループで回して（scripts/askhub-manual.sh を使う）"
    }

    /// 回答が付いた後などに、止まったループを再開するときの指示
    public static func resume(repository: String, discussionNumber: Int) -> String {
        "\(repository) の Discussion #\(discussionNumber) の手動ループを再開して（scripts/askhub-manual.sh resume）"
    }
}

/// 手動ループの担当者を表す、Discussion のコメント。
///
/// GitHub の Discussion には担当者（Assignees）の欄が無いので、先頭に目印を置いたコメントで表す。
/// 本文で担当者を @メンションするので、担当者に GitHub の通知が届く:
///
/// ```html
/// <!-- ask-hub:manual-assignee login="partner" -->
/// @partner さんが、この epic を手動ループで回します（AskHub から）。
/// ```
///
/// 信用する author が書いた目印のうち、最後のものを担当者とする（担当者を変えるときは、新しいコメントを足す）
public enum ManualLoopAssignment {
    static let keyword = "ask-hub:manual-assignee"

    /// 担当者を知らせるコメントの本文
    public static func comment(assignee: String, repository: String, discussionNumber: Int) -> String {
        """
        <!-- \(keyword) login="\(assignee)" -->
        @\(assignee) さんが、この epic を手動ループで回します（AskHub から）。

        担当者は、このリポジトリの checkout で開いた Claude Code に次の指示を貼ってください（AskHub のステータスタブの「手動ループ」からもコピーできます）:

        ```
        \(ManualLoopInstruction.start(repository: repository, discussionNumber: discussionNumber))
        ```
        """
    }

    /// コメントの本文から担当者の login を読む。目印が先頭に無い・login が不正なら `nil`
    public static func assignee(in body: String) -> String? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        let prefix = "<!-- \(keyword) login=\""
        guard trimmed.hasPrefix(prefix) else {
            return nil
        }
        let rest = trimmed.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: "\""), rest[end...].hasPrefix("\" -->") else {
            return nil
        }
        let login = String(rest[..<end])
        return isValidLogin(login) ? login : nil
    }

    /// 信用する author が書いた目印のうち、最後のものの担当者
    public static func latestAssignee(in comments: [(author: String?, body: String)], trustedAuthors: TrustedAuthors) -> String? {
        comments.last { trustedAuthors.contains($0.author) && assignee(in: $0.body) != nil }.flatMap { assignee(in: $0.body) }
    }

    /// GitHub の login の形式（英数字とハイフン、39 文字まで、先頭と末尾はハイフン以外）
    public static func isValidLogin(_ login: String) -> Bool {
        let allowed = CharacterSet.asciiAlphanumerics.union(CharacterSet(charactersIn: "-"))
        return (1...39).contains(login.count)
            && !login.hasPrefix("-") && !login.hasSuffix("-")
            && login.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
