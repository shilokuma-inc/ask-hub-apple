import AskHubKit
import Foundation

/// epic ごとの仮決め一覧（`decision-log` の open な Issue）
public struct DecisionLogIssue: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    public let title: String
    public let body: String

    public init(repository: String, number: Int, title: String, body: String) {
        self.repository = repository
        self.number = number
        self.title = title
        self.body = body
    }

    /// 仮決め一覧の epic ブランチ。タイトル（`【CHORE】<epic ブランチ> の仮決め一覧`）から読む。読めなければ `nil`
    public var branch: String? {
        guard let match = title.firstMatch(of: /^【CHORE】(epic\/\S+) の仮決め一覧$/) else {
            return nil
        }
        return String(match.1)
    }
}

/// Issue のコメント
public struct IssueComment: Sendable, Equatable {
    public let id: Int
    /// 削除済みのユーザーでは `nil`
    public let author: String?
    public let body: String

    public init(id: Int, author: String?, body: String) {
        self.id = id
        self.author = author
        self.body = body
    }
}

/// 仮決め一覧の読み取りと、閉じるときのコメント（副作用なし）
public enum DecisionLog {
    /// ループが仮決め一覧への指示に返信するときに置く目印。
    /// ループと人間は同じアカウントでコメントするため、author ではなくこの目印で返信を見分ける
    public static let replyMarker = "<!-- ask-hub:decision-reply -->"
    /// オーケストレーターが閉じるときのコメントに置く目印
    public static let closeMarker = "<!-- ask-hub:decision-close -->"

    /// まだ確認されていない（チェックの付いていない）仮決めの行。先頭の `- [ ] ` は除く
    public static func uncheckedItems(in body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") else {
                return nil
            }
            return trimmed.dropFirst("- [ ]".count).trimmingCharacters(in: .whitespaces)
        }
    }

    /// ループがまだ処理していない、信用する author のコメント。
    /// ループは扱ったコメントに目印付きで返信するので、最後の返信より後のコメントを未処理とみなす
    public static func unprocessedInstructions(in comments: [IssueComment], trustedAuthors: TrustedAuthors) -> [IssueComment] {
        let isMarked = { (comment: IssueComment) in
            comment.body.contains(replyMarker) || comment.body.contains(closeMarker)
        }
        let start = comments.lastIndex(where: isMarked).map { $0 + 1 } ?? comments.startIndex
        return comments[start...].filter { !isMarked($0) && trustedAuthors.contains($0.author) }
    }

    /// 最終 PR のマージを受けて閉じるときのコメント
    public static func closingComment(pullRequest: Int, uncheckedItems: [String]) -> String {
        var lines = [closeMarker, "epic の最終 PR #\(pullRequest) がマージされたので、この仮決め一覧を閉じます。", ""]
        if uncheckedItems.isEmpty {
            lines.append("すべての仮決めが確認済みです。")
        } else {
            lines.append("次の \(uncheckedItems.count) 件は返答が無かったため、既定値のまま確定しました。")
            lines.append(contentsOf: uncheckedItems.map { "- \($0)" })
        }
        lines.append("")
        lines.append("マージ後にこの Issue へコメントしても、ループは動きません。変更したいものは Issue か AskHub の依頼から出してください。")
        return lines.joined(separator: "\n")
    }
}
