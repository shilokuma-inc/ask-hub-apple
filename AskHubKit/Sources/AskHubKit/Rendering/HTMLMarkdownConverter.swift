import Foundation

/// GitHub のコメント本文に混ざる HTML タグを、Markdown 相当のテキストに変換する。
///
/// 質問コメントやマージ待ちの PR 本文には `<h3>Q2. …</h3>` のような HTML が含まれることがあり、
/// GitHub では見出しになるがアプリでは文字のまま出てしまう。`NSAttributedString` の HTML インポーターや
/// `WKWebView` は使わず、よく使うタグだけを Markdown に置き換えてから Markdown として解釈する
/// （Discussion #128 の決定）。
///
/// | HTML | Markdown |
/// | --- | --- |
/// | `<h1>`〜`<h6>` | `#`〜`######` の見出し |
/// | `<b>` `<strong>` / `<i>` `<em>` | `**太字**` / `*斜体*` |
/// | `<br>` | 行末の 2 つの空白と改行（ハードブレーク） |
/// | `<p>` | 前後に空行 |
/// | `<ul>` `<ol>` `<li>` | `- ` / `1. ` の箇条書き（入れ子はインデント） |
/// | `<code>` / `<pre>` | コードスパン / フェンスドコードブロック |
/// | `<a href>` | `[文字](URL)`。`http(s)` 以外のスキームは文字だけ残す |
/// | HTML コメント | 取り除く（先頭の `<!-- ask-hub:question … -->` も含む） |
/// | `<table>` `<tr>` `<th>` `<td>` | Markdown の表（`\| a \| b \|` と区切り行）。セルは 1 行にし、`\|` をエスケープする |
/// | それ以外のタグ | タグだけ取り除いて中の文字を残す（`<details>`・`<img>` など。`<img>` の alt も出さない） |
///
/// - Markdown のコードスパン・フェンスドコードブロックの中はタグもエンティティも解釈せず、そのまま残す
/// - `&amp;` などのエンティティは、`<pre>` / `<code>` の中だけこの変換でデコードする。
///   それ以外は Markdown パーサーがデコードするので、二重にデコードしないよう手を付けない
/// - 閉じ忘れ・入れ子の崩れ・未知のタグがあってもクラッシュせず、文字を失わない
/// - 変換は表示のためだけに行う。`<script>` の実行やリンク先・画像の読み込みはしない
public enum HTMLMarkdownConverter {
    /// HTML を含む本文を Markdown 相当のテキストに変換する。
    ///
    /// 前後の空白・改行は取り除く。HTML を含まない本文はほぼそのまま返る
    public static func convert(_ html: String) -> String {
        var conversion = HTMLMarkdownConversion(input: html)
        return conversion.run()
    }

    /// `&amp;` `&lt;` `&#39;` `&#x1F600;` などの文字参照をデコードする。
    ///
    /// 名前付き参照は `amp` `lt` `gt` `quot` `apos` `nbsp` を扱う。解釈できないものはそのまま残す
    public static func decodeEntities(_ text: String) -> String {
        HTMLEntities.decode(text)
    }
}

/// 1 回の変換の状態。入力を先頭から 1 文字ずつ読み、Markdown を `output` に組み立てる
struct HTMLMarkdownConversion {
    let chars: [Character]
    var index = 0
    var output = MarkdownOutput()
    /// 文字と文字の間の空白・改行。次の文字の直前に書き出し、ブロック要素のタグが来たら捨てる
    var pendingWhitespace: [Character] = []
    /// 開いたままのインライン要素（太字・斜体・リンク・見出し）。閉じタグで Markdown の記号に確定する
    var inlineStack: [InlineMarker] = []
    /// 開いたままの箇条書き
    var listStack: [ListContext] = []
    /// `<pre>` / `<code>` の中を読んでいる間の内容
    var codeBuffer: CodeBuffer?
    /// 開いたままの表。入れ子の表は外側の表のセルの文字として扱うので、同時に開くのは 1 つだけ
    var table: HTMLTableContext?

    init(input: String) {
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        chars = Array(normalized)
    }

    mutating func run() -> String {
        while index < chars.count {
            if codeBuffer != nil {
                scanInsideCode()
            } else {
                scanText()
            }
        }
        if let buffer = codeBuffer {
            codeBuffer = nil
            emit(code: buffer)
        }
        // 閉じられていない表（入れ子も）を閉じて、読んだところまでを表にする
        while table != nil {
            closeTablePart(.table)
        }
        closeAllInline()
        return output.finish()
    }

    // MARK: - 通常のテキスト

    private mutating func scanText() {
        let char = chars[index]
        if char == "<" {
            if hasPrefix("<!--") {
                if let close = find("-->", from: index + 4) {
                    index = close + 3
                } else {
                    // 閉じられていないコメントは文字として残す（文字を失わないため）
                    appendText(char)
                    index += 1
                }
                return
            }
            if let tag = HTMLTag.parse(chars, at: index) {
                index = tag.endIndex
                handle(tag)
                return
            }
            appendText(char)
            index += 1
            return
        }
        if char == "`" || char == "~", let literal = markdownCodeRange(at: index) {
            flushPendingWhitespace()
            output.append(contentsOf: chars[literal])
            index = literal.upperBound
            return
        }
        if char.isWhitespace {
            pendingWhitespace.append(char)
        } else {
            appendText(char)
        }
        index += 1
    }

    private mutating func appendText(_ char: Character) {
        flushPendingWhitespace()
        output.append(char)
    }

    mutating func flushPendingWhitespace() {
        defer { pendingWhitespace.removeAll() }
        guard !pendingWhitespace.isEmpty else {
            return
        }
        var whitespace = pendingWhitespace[...]
        if output.dropsIndentation {
            // ブロック要素の直後の改行とインデントは HTML の整形なので捨てる。
            // 残すと Markdown のインデント付きコードブロックに見えてしまう
            if let lastNewline = whitespace.lastIndex(where: \.isNewline) {
                whitespace = whitespace[lastNewline...]
            } else {
                return
            }
        }
        for char in whitespace where !(char.isNewline && output.endsWithBlankLine) {
            output.append(char)
        }
    }

    // MARK: - Markdown のコード

    /// `index` から始まる Markdown のコードスパン・フェンスドコードブロックの範囲。該当しなければ `nil`
    private func markdownCodeRange(at start: Int) -> Range<Int>? {
        let fence = chars[start]
        var end = start
        while end < chars.count, chars[end] == fence {
            end += 1
        }
        let length = end - start
        if length >= 3, isAtMarkdownLineStart(start) {
            return start..<(fencedBlockEnd(fence: fence, length: length, from: end) ?? chars.count)
        }
        guard fence == "`", let close = codeSpanClose(length: length, from: end) else {
            return nil
        }
        return start..<close
    }

    /// 行頭（3 つまでの空白は許す）か
    private func isAtMarkdownLineStart(_ position: Int) -> Bool {
        var cursor = position
        var spaces = 0
        while cursor > 0, chars[cursor - 1] == " " {
            cursor -= 1
            spaces += 1
        }
        return spaces <= 3 && (cursor == 0 || chars[cursor - 1].isNewline)
    }

    /// フェンスを閉じる行の終わり（閉じフェンスの直後）。閉じられていなければ `nil`
    private func fencedBlockEnd(fence: Character, length: Int, from start: Int) -> Int? {
        var cursor = start
        while let newline = chars[cursor...].firstIndex(where: \.isNewline) {
            var lineStart = newline + 1
            var spaces = 0
            while lineStart < chars.count, chars[lineStart] == " ", spaces < 3 {
                lineStart += 1
                spaces += 1
            }
            var fenceEnd = lineStart
            while fenceEnd < chars.count, chars[fenceEnd] == fence {
                fenceEnd += 1
            }
            var lineEnd = fenceEnd
            while lineEnd < chars.count, chars[lineEnd] == " " || chars[lineEnd] == "\t" {
                lineEnd += 1
            }
            if fenceEnd - lineStart >= length, lineEnd == chars.count || chars[lineEnd].isNewline {
                return lineEnd
            }
            cursor = newline + 1
        }
        return nil
    }

    /// 同じ数のバッククォートで閉じられる位置（閉じの直後）。閉じられていなければ `nil`
    private func codeSpanClose(length: Int, from start: Int) -> Int? {
        var cursor = start
        while cursor < chars.count {
            guard chars[cursor] == "`" else {
                cursor += 1
                continue
            }
            var end = cursor
            while end < chars.count, chars[end] == "`" {
                end += 1
            }
            if end - cursor == length {
                return end
            }
            cursor = end
        }
        return nil
    }

    // MARK: - HTML の pre / code の中

    private mutating func scanInsideCode() {
        let char = chars[index]
        if char == "<" {
            if hasPrefix("<!--"), let close = find("-->", from: index + 4) {
                index = close + 3
                return
            }
            if let tag = HTMLTag.parse(chars, at: index) {
                index = tag.endIndex
                if tag.isClosing, tag.name == codeBuffer?.kind.tagName {
                    if let buffer = codeBuffer {
                        codeBuffer = nil
                        emit(code: buffer)
                    }
                } else if tag.name == "br" {
                    codeBuffer?.content.append("\n")
                }
                // コードの中の他のタグ（`<pre><code>` の `<code>` など）は取り除いて文字だけ残す
                return
            }
        }
        if char == "&", let entity = HTMLEntities.decode(chars, at: index) {
            codeBuffer?.content.append(contentsOf: entity.text)
            index = entity.endIndex
            return
        }
        codeBuffer?.content.append(char)
        index += 1
    }

    mutating func emit(code buffer: CodeBuffer) {
        switch buffer.kind {
        case .block:
            closeAllInline()
            pendingWhitespace.removeAll()
            let content = buffer.blockContent
            guard !content.isEmpty else {
                return
            }
            let fence = String(repeating: "`", count: max(3, buffer.longestBacktickRun + 1))
            output.ensureBlankLine()
            output.append(contentsOf: fence + "\n" + content + "\n" + fence)
            output.ensureBlankLine()

        case .inline:
            let content = String(buffer.content)
            guard !content.isEmpty else {
                return
            }
            flushPendingWhitespace()
            let delimiter = String(repeating: "`", count: buffer.longestBacktickRun + 1)
            // 内容がバッククォートで始まる・終わるときは、区切りとくっつかないよう空白で挟む
            let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
            output.append(contentsOf: delimiter + padding + content + padding + delimiter)
        }
    }

    // MARK: - 入力の探索

    private func hasPrefix(_ text: String) -> Bool {
        let pattern = Array(text)
        guard index + pattern.count <= chars.count else {
            return false
        }
        return chars[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private func find(_ text: String, from start: Int) -> Int? {
        let pattern = Array(text)
        guard pattern.count <= chars.count else {
            return nil
        }
        var cursor = start
        while cursor + pattern.count <= chars.count {
            if chars[cursor..<(cursor + pattern.count)].elementsEqual(pattern) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }
}
