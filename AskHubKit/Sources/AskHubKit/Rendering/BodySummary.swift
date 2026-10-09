import Foundation

/// 一覧に出す要約。本文（Markdown と HTML の混在）からタグとブロック記号を取り除き、文字だけを 1 行につなげる。
///
/// 一覧の行は 1 行につなげるので、見出し・箇条書きの見た目は付けない（Discussion #128 の Q3）。
/// 先頭の目印（HTML コメント）とバッジなどの画像は出さない
public enum BodySummary {
    public static func oneLine(_ body: String) -> String {
        let markdown = HTMLMarkdownConverter.convert(body)
        let joined = strippingBlockMarkers(markdown).joined(separator: " ")
        return collapsingWhitespace(resolvingInlineMarkdown(joined))
    }

    /// 行ごとに見出し・箇条書き・引用の記号を取り除く。コードフェンスの行は落とし、中の文字は残す
    private static func strippingBlockMarkers(_ markdown: String) -> [String] {
        var lines: [String] = []
        var openFence: Fence?
        /// 表の中の行か（ヘッダー行と区切り行の組から、`|` で始まらない行まで）
        var isInTable = false
        let rawLines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in rawLines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence = Fence(line: rawLine) {
                // フェンスは表を終わらせる（中身の無いフェンスでも、後の行は新しい区切り行があるときだけ表にする）
                isInTable = false
                if let open = openFence {
                    // 同じ文字で同じ長さ以上のフェンスだけが閉じる（```` の中の ``` は中身）
                    if fence.closes(open) {
                        openFence = nil
                        continue
                    }
                } else {
                    openFence = fence
                    continue
                }
            }
            guard openFence == nil else {
                isInTable = false
                if !line.isEmpty {
                    lines.append(line)
                }
                continue
            }
            let content = line.replacing(blockMarkerPattern, with: "")
            if content.hasPrefix("|"), !isInTable, index + 1 < rawLines.count {
                // GFM と同じく、直後が区切り行のときだけ表の始まりとみなす（`| 単独の行` は表ではない）
                let next = rawLines[index + 1].trimmingCharacters(in: .whitespaces).replacing(blockMarkerPattern, with: "")
                isInTable = isDelimiterRow(next)
            } else if !content.hasPrefix("|") {
                isInTable = false
            }
            let stripped = (isInTable ? strippingTableRow(content) : content).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                lines.append(stripped)
            }
        }
        return lines
    }

    /// 行頭（3 つまでの空白を許す）のコードフェンス（``` か ~~~ が 3 つ以上）
    private struct Fence {
        let character: Character
        let length: Int
        /// フェンスの後に文字が無い（閉じフェンスになれる）か
        let isAlone: Bool

        init?(line: Substring) {
            let trimmed = line.drop { $0 == " " }
            guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else {
                return nil
            }
            let run = trimmed.prefix { $0 == first }
            guard run.count >= 3 else {
                return nil
            }
            character = first
            length = run.count
            isAlone = trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace)
        }

        func closes(_ open: Fence) -> Bool {
            character == open.character && length >= open.length && isAlone
        }
    }

    /// 表の行の、セルの区切りの `|` を空白にする。区切り行（`| --- | :-: |`）は空にする
    private static func strippingTableRow(_ line: String) -> String {
        let cells = tableCells(line)
        return isDelimiterRow(line) ? "" : cells.joined(separator: " ")
    }

    /// 区切り行（`| --- | :-: |`）か
    private static func isDelimiterRow(_ line: String) -> Bool {
        let cells = tableCells(line)
        return line.hasPrefix("|") && !cells.isEmpty && cells.allSatisfy { $0.wholeMatch(of: delimiterCellPattern) != nil }
    }

    /// 表の行を `|` で分けたセル（前後の空白を除き、空のセルは除く）。
    /// エスケープされた `\|`（直前の `\` が奇数個）はセルの文字なので残す（後のインラインの解釈で `|` になる）
    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var backslashes = 0
        for char in line {
            if char == "|", backslashes.isMultiple(of: 2) {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(char)
            }
            backslashes = char == "\\" ? backslashes + 1 : 0
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 表の区切り行のセル（`---`・`:-:` など）
    private static var delimiterCellPattern: Regex<Substring> {
        /:?-+:?/
    }

    /// 行頭の `>`・`#`・`-` `*` `+`・`1.` `1)`（組み合わせも）。`Regex` は Sendable でないので computed property にする
    private static var blockMarkerPattern: Regex<Substring> {
        /^(?:(?:>+|#{1,6}|[-*+]|\d{1,9}[.)])(?:\s+|$))+/
    }

    /// 太字・コード・リンクなどのインラインの記号を解釈して文字だけにする（エンティティもデコードされる）。
    /// 画像（`ask-badge` などのバッジ）は解釈した結果の run で除く（正規表現で先に消すとコードの中の `![alt](url)` まで消える）
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
