import Foundation

/// 一覧に出す要約。本文（Markdown と HTML の混在）からタグとブロック記号を取り除き、文字だけを 1 行につなげる。
///
/// 一覧の行は 1 行につなげるので、見出し・箇条書きの見た目は付けない（Discussion #128 の Q3）。
/// 先頭の目印（HTML コメント）とバッジなどの画像は出さない
public enum BodySummary {
    public static func oneLine(_ body: String) -> String {
        let markdown = HTMLMarkdownConverter.convert(body).replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        let joined = strippingBlockMarkers(markdown).joined(separator: " ")
        return collapsingWhitespace(resolvingInlineMarkdown(joined))
    }

    /// 行ごとに見出し・箇条書き・引用の記号を取り除く。コードフェンスの行は落とし、中の文字は残す
    private static func strippingBlockMarkers(_ markdown: String) -> [String] {
        var lines: [String] = []
        var isInsideFence = false
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideFence.toggle()
                continue
            }
            let stripped = isInsideFence ? line : line.replacing(blockMarkerPattern, with: "").trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                lines.append(stripped)
            }
        }
        return lines
    }

    /// 行頭の `>`・`#`・`-` `*` `+`・`1.` `1)`（組み合わせも）。`Regex` は Sendable でないので computed property にする
    private static var blockMarkerPattern: Regex<Substring> {
        /^(?:(?:>+|#{1,6}|[-*+]|\d{1,9}[.)])(?:\s+|$))+/
    }

    /// 太字・コード・リンクなどのインラインの記号を解釈して文字だけにする（エンティティもデコードされる）
    private static func resolvingInlineMarkdown(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return text
        }
        return attributed.runs
            .filter { $0.imageURL == nil }
            .map { String(attributed[$0.range].characters) }
            .joined()
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension InboxQuestion {
    /// 一覧に出す質問の要約（1 行）
    public var summary: String {
        BodySummary.oneLine(questionBody)
    }
}
