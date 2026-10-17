import Foundation

/// 最終 PR（`epic-final`）のコメント（Issue コメント）の履歴と、指示が処理済みかの判定（副作用なし）。
/// 取り決めは `docs/protocol.md` の「最終 PR への指示」。考え方は仮決め一覧の `DecisionLogHistory` と同じ
public struct FinalPullRequestHistory: Sendable, Equatable {
    /// 履歴の 1 件
    public struct Entry: Sendable, Equatable, Identifiable {
        public let comment: IssueComment
        public let kind: Kind

        public var id: Int {
            comment.id
        }
    }

    /// コメントの種類
    public enum Kind: Sendable, Equatable {
        /// 信用する author の指示。最後の返信（目印）より前なら処理済み
        case instruction(isProcessed: Bool)
        /// ループの返信（信用する author の `FinalPullRequestMarker.reply` 付きのコメント）
        case reply
        /// オーケストレーターのコメント（信用する author の `FinalPullRequestMarker.orchestrator` で始まるコメントと、
        /// 目印を付ける前の形（末尾が `FinalPullRequestMarker.legacyOrchestratorSuffix`）のコメント）。指示でも返信でもない
        case orchestrator
        /// CodeRabbit への依頼（`@coderabbitai review` など、`@coderabbitai` で始まり、指摘を指していないコメント）。ループへの指示ではない
        case codeRabbitCommand
        /// 信用する author 以外のコメント（CodeRabbit を含む）。指示として扱わず、目印を含んでいても処理済みの判定に使わない
        case untrusted
    }

    /// 古い順（作成順）の履歴
    public let entries: [Entry]

    /// `comments` は古い順（作成順）に並べて渡す。最後の返信より後の信用する author のコメントを未処理とみなすため
    public init(comments: [IssueComment], trustedAuthors: TrustedAuthors) {
        let kinds = comments.map { Self.kind(of: $0, trustedAuthors: trustedAuthors) }
        let lastReply = kinds.lastIndex(of: .reply)
        entries = zip(comments.indices, comments).map { index, comment in
            var kind = kinds[index]
            if case .instruction = kind {
                kind = .instruction(isProcessed: lastReply.map { index < $0 } ?? false)
            }
            return Entry(comment: comment, kind: kind)
        }
    }

    /// ループがまだ処理していない指示（古い順）
    public var unprocessedInstructions: [IssueComment] {
        entries.filter { $0.kind == .instruction(isProcessed: false) }.map(\.comment)
    }

    /// ループがまだ処理していない、信用する author のコメント。
    /// ループは扱ったコメントに目印付きで返信するので、最後の返信より後のコメントを未処理とみなす
    public static func unprocessedInstructions(in comments: [IssueComment], trustedAuthors: TrustedAuthors) -> [IssueComment] {
        Self(comments: comments, trustedAuthors: trustedAuthors).unprocessedInstructions
    }

    /// 指示が指す PR のレビューコメント（CodeRabbit の指摘など）の id。本文の `#discussion_r<id>`（会話のタブのリンク）と
    /// `#r<id>`（Files changed のタブのリンク）から、出てきた順に重複なく読む。
    /// id は REST のレビューコメントの id（GraphQL の `databaseId`）。指示が指摘を指していなければ空
    public static func referencedReviewComments(in body: String) -> [Int] {
        var ids: [Int] = []
        for match in body.matches(of: reviewCommentAnchor) {
            if let id = Int(match.output.1), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// `#discussion_r<id>` / `#r<id>` のアンカー（`#readme` などを拾わないよう、数字が続くものだけ）。
    /// `Regex` は `Sendable` ではないので computed property にする
    private static var reviewCommentAnchor: Regex<(Substring, Substring)> {
        /#(?:discussion_)?r(\d+)\b/
    }

    /// 目印は本文の先頭（前の空白・改行は無視する）にあるときだけ認める。
    /// 指示が CodeRabbit の指摘などを引用し、その中に目印が含まれていても、指示を返信や無視するコメントと取り違えないため
    private static func kind(of comment: IssueComment, trustedAuthors: TrustedAuthors) -> Kind {
        guard trustedAuthors.contains(comment.author) else {
            return .untrusted
        }
        let body = comment.body.drop { $0.isWhitespace }
        if body.hasPrefix(FinalPullRequestMarker.reply) {
            return .reply
        }
        if body.hasPrefix(FinalPullRequestMarker.orchestrator)
            || body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(FinalPullRequestMarker.legacyOrchestratorSuffix) {
            return .orchestrator
        }
        // CodeRabbit の指摘を指すものは、書き出しが CodeRabbit 宛てでもループへの指示として扱う
        if body.lowercased().hasPrefix(FinalPullRequestMarker.codeRabbitMention), referencedReviewComments(in: comment.body).isEmpty {
            return .codeRabbitCommand
        }
        return .instruction(isProcessed: false)
    }
}
