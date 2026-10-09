import Foundation

/// 本文から読み取った HTML のタグ 1 つ
struct HTMLTag {
    /// 小文字にしたタグ名
    let name: String
    let isClosing: Bool
    /// 小文字にした属性名 → 値。値のクォートは外してある
    let attributes: [String: String]
    /// タグの直後の位置
    let endIndex: Int

    /// `start` の `<` から始まるタグを読み取る。タグの形になっていなければ `nil`（`<` は文字として扱う）
    static func parse(_ chars: [Character], at start: Int) -> Self? {
        var cursor = start + 1
        let isClosing = cursor < chars.count && chars[cursor] == "/"
        if isClosing {
            cursor += 1
        }
        guard let first = chars[safe: cursor],
              first.isLetter || (!isClosing && (first == "!" || first == "?")) else {
            return nil
        }
        var name = ""
        while let char = chars[safe: cursor], char.isLetter || char.isNumber || char == "!" || char == "?" {
            name.append(char)
            cursor += 1
        }
        guard let (attributes, end) = parseAttributes(chars, from: cursor) else {
            return nil
        }
        return Self(name: name.lowercased(), isClosing: isClosing, attributes: attributes, endIndex: end)
    }

    /// 属性の並びを `>` まで読む。クォートの中の `>` はタグの終わりとみなさない。`>` が無ければ `nil`
    private static func parseAttributes(_ chars: [Character], from start: Int) -> ([String: String], Int)? {
        var attributes: [String: String] = [:]
        var cursor = start
        while let char = chars[safe: cursor] {
            if char == ">" {
                return (attributes, cursor + 1)
            }
            if char.isWhitespace || char == "/" {
                cursor += 1
                continue
            }
            if char == "<" {
                // 閉じられていないタグ。次のタグの前までを文字として扱わせる
                return nil
            }
            var attributeName = ""
            while let char = chars[safe: cursor], !char.isWhitespace, !["=", ">", "/"].contains(char) {
                attributeName.append(char)
                cursor += 1
            }
            cursor = skippingWhitespace(chars, from: cursor)
            var value = ""
            if chars[safe: cursor] == "=" {
                guard let (parsed, end) = parseAttributeValue(chars, from: skippingWhitespace(chars, from: cursor + 1)) else {
                    return nil
                }
                value = parsed
                cursor = end
            }
            if !attributeName.isEmpty, attributes[attributeName.lowercased()] == nil {
                attributes[attributeName.lowercased()] = value
            }
        }
        return nil
    }

    /// `=` の後の値を読む。クォート付きなら閉じクォートまで、無ければ空白か `>` の前まで。閉じクォートが無ければ `nil`
    private static func parseAttributeValue(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard let quote = chars[safe: start] else {
            return nil
        }
        var value = ""
        var cursor = start
        if quote == "\"" || quote == "'" {
            cursor += 1
            while let char = chars[safe: cursor], char != quote {
                value.append(char)
                cursor += 1
            }
            guard cursor < chars.count else {
                return nil
            }
            return (value, cursor + 1)
        }
        while let char = chars[safe: cursor], !char.isWhitespace, char != ">" {
            value.append(char)
            cursor += 1
        }
        return (value, cursor)
    }

    private static func skippingWhitespace(_ chars: [Character], from start: Int) -> Int {
        var cursor = start
        while let char = chars[safe: cursor], char.isWhitespace {
            cursor += 1
        }
        return cursor
    }

    /// タグ名ごとの変換のしかた
    enum Kind {
        case heading(Int)
        /// `**` か `*`
        case emphasis(String)
        case link
        case lineBreak
        case paragraph
        case list(ordered: Bool)
        case listItem
        case code(CodeBuffer.Kind)
        /// 中身の文字だけ残し、前後で改行する（`<details>`・`<div>` など）
        case block
        /// `<table>`。Markdown の表にする
        case table
        /// `<thead>`（`isHead` が真）・`<tbody>`・`<tfoot>`
        case tableSection(isHead: Bool)
        case tableRow
        /// `<th>`・`<td>`
        case tableCell
        /// タグだけ取り除く（`<span>` `<img>` など）
        case ignored

        init(name: String) {
            if let kind = Self.byName[name] {
                self = kind
            } else if Self.blockNames.contains(name) {
                self = .block
            } else {
                self = .ignored
            }
        }

        var isHeading: Bool {
            if case .heading = self {
                return true
            }
            return false
        }

        private static let byName: [String: Kind] = [
            "h1": .heading(1), "h2": .heading(2), "h3": .heading(3), "h4": .heading(4), "h5": .heading(5), "h6": .heading(6),
            "b": .emphasis("**"), "strong": .emphasis("**"), "i": .emphasis("*"), "em": .emphasis("*"),
            "a": .link, "br": .lineBreak, "p": .paragraph,
            "ul": .list(ordered: false), "ol": .list(ordered: true), "li": .listItem,
            "pre": .code(.block), "code": .code(.inline),
            "table": .table, "thead": .tableSection(isHead: true), "tbody": .tableSection(isHead: false),
            "tfoot": .tableSection(isHead: false), "tr": .tableRow, "td": .tableCell, "th": .tableCell
        ]

        private static let blockNames: Set<String> = [
            "div", "section", "article", "header", "footer", "nav", "aside", "main", "address", "center",
            "caption",
            "details", "summary", "blockquote", "hr", "dl", "dt", "dd", "figure", "figcaption"
        ]
    }
}

extension Array where Element == Character {
    /// 範囲外なら `nil`
    subscript(safe index: Int) -> Character? {
        indices.contains(index) ? self[index] : nil
    }
}
