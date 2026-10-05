import Foundation

/// `HTMLMarkdownConversion` が Markdown を組み立てる出力バッファ。
///
/// 末尾の状態（行頭か・空行か）を見ながら、改行や空行を必要なぶんだけ入れる
struct MarkdownOutput {
    private var chars: [Character] = []
    /// 直前にブロック要素の境界を作ったか。真の間は、次に書く文字の前の整形用インデントを捨てる
    private(set) var dropsIndentation = true
    /// 箇条書きの記号を書いた直後か。真の間は、`<li><p>` のようなブロック要素の境界で改行を入れない
    private var isAtListItemStart = false

    var count: Int {
        chars.count
    }

    var isAtLineStart: Bool {
        chars.last.map(\.isNewline) ?? true
    }

    var endsWithBlankLine: Bool {
        chars.isEmpty || (chars.count >= 2 && chars[chars.count - 1].isNewline && chars[chars.count - 2].isNewline)
    }

    mutating func append(_ char: Character) {
        chars.append(char)
        dropsIndentation = false
        isAtListItemStart = false
    }

    mutating func append(contentsOf text: some Sequence<Character>) {
        for char in text {
            append(char)
        }
    }

    /// 行頭でなければ改行する
    mutating func ensureNewline() {
        guard !isAtListItemStart else {
            return
        }
        trimTrailingSpaces()
        if !isAtLineStart {
            chars.append("\n")
        }
        dropsIndentation = true
    }

    /// 直前が空行でなければ空行を入れる。先頭では何もしない
    mutating func ensureBlankLine() {
        guard !isAtListItemStart else {
            return
        }
        trimTrailingSpaces()
        guard !chars.isEmpty else {
            dropsIndentation = true
            return
        }
        ensureNewline()
        if !endsWithBlankLine {
            chars.append("\n")
        }
    }

    /// 行末の空白・タブを取り除く（改行は残す）
    mutating func trimTrailingSpaces() {
        while let last = chars.last, last == " " || last == "\t" {
            chars.removeLast()
        }
    }

    mutating func beginListItem() {
        isAtListItemStart = true
    }

    func suffix(from start: Int) -> [Character] {
        Array(chars[min(start, chars.count)...])
    }

    mutating func replaceSuffix(from start: Int, with replacement: [Character]) {
        chars.removeSubrange(min(start, chars.count)...)
        chars.append(contentsOf: replacement)
    }

    func finish() -> String {
        String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 開いたままのインライン要素
struct InlineMarker {
    enum Kind {
        /// 見出しのレベル（1〜6）
        case heading(Int)
        /// `**` か `*`
        case emphasis(String)
        case link(href: String?)

        /// 内容が確定したときの Markdown。前後の空白は記号の外に出し、内容が空なら記号を出さない
        func markdown(content: [Character]) -> [Character] {
            let parts = WhitespaceSplit(content)
            switch self {
            case .heading(let level):
                // 見出しは 1 行にする。内容が無ければ見出しごと出さない
                guard !parts.core.isEmpty else {
                    return []
                }
                return Array(String(repeating: "#", count: level) + " ") + parts.core.map { $0.isNewline ? " " : $0 }

            case .emphasis(let marker):
                return parts.core.isEmpty ? parts.leading + parts.trailing : parts.wrapped(in: Array(marker), Array(marker))

            case .link(let href):
                guard let destination = Self.destination(for: href) else {
                    return parts.leading + parts.core + parts.trailing
                }
                let text = parts.core.isEmpty ? Array(destination.text) : parts.core
                return parts.leading + ["["] + text + Array("](" + destination.markdown + ")") + parts.trailing
            }
        }

        /// `href` を Markdown のリンク先にする。`http(s)` 以外のスキーム（`javascript:` など）は `nil`
        private static func destination(for href: String?) -> (text: String, markdown: String)? {
            guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
                return nil
            }
            let lowered = href.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
                  !href.contains("<"), !href.contains(">") else {
                return nil
            }
            let needsBrackets = href.contains { $0.isWhitespace || $0 == "(" || $0 == ")" }
            return (href, needsBrackets ? "<\(href)>" : href)
        }
    }

    let tag: String
    let kind: Kind
    /// 開始記号（`**` や `[` や `### `）を書き始めた位置
    let markerStart: Int
    /// 内容が始まる位置
    let contentStart: Int

    /// 閉じタグがこの要素を閉じるか。見出しは `<h2>…</h3>` のように番号がずれていても閉じる
    func matches(closingTag: String) -> Bool {
        if case .heading = kind {
            return HTMLTag.Kind(name: closingTag).isHeading
        }
        return tag == closingTag
    }
}

/// 開いたままの箇条書き
struct ListContext {
    let ordered: Bool
    /// 記号を書き始める桁
    let indent: Int
    private var counter = 0
    /// 直近の記号の幅。入れ子の箇条書きはこのぶんインデントする
    private(set) var markerWidth = 2

    init(ordered: Bool, indent: Int) {
        self.ordered = ordered
        self.indent = indent
    }

    mutating func nextMarker() -> String {
        counter += 1
        let marker = ordered ? "\(counter). " : "- "
        markerWidth = marker.count
        return marker
    }
}

/// `<pre>` / `<code>` の中身
struct CodeBuffer {
    enum Kind {
        /// `<pre>`。フェンスドコードブロックにする
        case block
        /// `<code>`。コードスパンにする
        case inline

        var tagName: String {
            switch self {
            case .block:
                "pre"

            case .inline:
                "code"
            }
        }
    }

    let kind: Kind
    var content: [Character] = []

    init(kind: Kind) {
        self.kind = kind
    }

    var longestBacktickRun: Int {
        var longest = 0
        var current = 0
        for char in content {
            current = char == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    /// コードブロックの中身。HTML と同じく `<pre>` 直後の改行 1 つを除き、末尾の空白・改行を落とす
    var blockContent: String {
        var text = content[...]
        if text.first?.isNewline == true {
            text = text.dropFirst()
        }
        while let last = text.last, last.isWhitespace {
            text = text.dropLast()
        }
        return String(text)
    }
}

/// 内容を前後の空白と中身に分けたもの
struct WhitespaceSplit {
    let leading: [Character]
    let core: [Character]
    let trailing: [Character]

    init(_ content: [Character]) {
        let leadingEnd = content.firstIndex { !$0.isWhitespace } ?? content.count
        let rest = content[leadingEnd...]
        let trailingStart = rest.lastIndex { !$0.isWhitespace }.map { $0 + 1 } ?? rest.startIndex
        leading = Array(content[..<leadingEnd])
        core = Array(rest[..<trailingStart])
        trailing = Array(rest[trailingStart...])
    }

    func wrapped(in open: [Character], _ close: [Character]) -> [Character] {
        leading + open + core + close + trailing
    }
}
