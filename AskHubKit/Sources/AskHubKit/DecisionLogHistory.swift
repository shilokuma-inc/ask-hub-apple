import Foundation

/// 仮決め一覧のコメントの履歴と、指示が処理済みかの判定（副作用なし）。
/// 取り決めは `docs/protocol.md` の「指示が処理済みかの判定」。オーケストレーターの `DecisionLog.unprocessedInstructions` もこれを使う
public struct DecisionLogHistory: Sendable, Equatable {
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
        /// ループの返信（信用する author の `DecisionLogMarker.reply` 付きのコメント）
        case reply
        /// オーケストレーターが閉じるときのコメント（信用する author の `DecisionLogMarker.close` 付きのコメント）
        case close
        /// 信用する author 以外のコメント。指示として扱わず、目印を含んでいても処理済みの判定に使わない
        case untrusted
    }

    /// 古い順（作成順）の履歴
    public let entries: [Entry]

    /// `comments` は古い順（作成順）に並べて渡す。最後の目印より後の信用する author のコメントを未処理とみなすため
    public init(comments: [IssueComment], trustedAuthors: TrustedAuthors) {
        let lastMarked = comments.lastIndex { Self.marker(of: $0, trustedAuthors: trustedAuthors) != nil }
        entries = comments.enumerated().map { index, comment in
            let kind: Kind
            if !trustedAuthors.contains(comment.author) {
                kind = .untrusted
            } else if let marker = Self.marker(of: comment, trustedAuthors: trustedAuthors) {
                kind = marker
            } else {
                kind = .instruction(isProcessed: lastMarked.map { index < $0 } ?? false)
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

    /// 信用する author が書いた、`marker` 付きのコメントか。
    /// public リポジトリでは誰でも目印を書けるので、それ以外の author の目印で未処理の指示や閉じるときのコメントを消させない
    public static func isTrustedMarked(_ comment: IssueComment, with marker: String, trustedAuthors: TrustedAuthors) -> Bool {
        trustedAuthors.contains(comment.author) && comment.body.contains(marker)
    }

    /// 信用する author の目印付きのコメントなら、その種類。両方の目印を含むときは返信として扱う
    private static func marker(of comment: IssueComment, trustedAuthors: TrustedAuthors) -> Kind? {
        if isTrustedMarked(comment, with: DecisionLogMarker.reply, trustedAuthors: trustedAuthors) {
            return .reply
        }
        if isTrustedMarked(comment, with: DecisionLogMarker.close, trustedAuthors: trustedAuthors) {
            return .close
        }
        return nil
    }
}
