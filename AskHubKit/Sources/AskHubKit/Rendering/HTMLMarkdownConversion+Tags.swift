import Foundation

// タグごとの変換
extension HTMLMarkdownConversion {
    mutating func handle(_ tag: HTMLTag) {
        if tag.isClosing {
            handleClosing(tag)
        } else {
            handleOpening(tag)
        }
    }

    private mutating func handleOpening(_ tag: HTMLTag) {
        let kind = HTMLTag.Kind(name: tag.name)
        switch kind {
        case .heading(let level):
            openHeading(level: level)

        case .emphasis(let marker):
            openInline(.emphasis(marker), tag: tag.name)

        case .link:
            openInline(.link(href: tag.attributes["href"]), tag: tag.name)

        case .lineBreak:
            flushPendingWhitespace()
            output.trimTrailingSpaces()
            output.append(contentsOf: "  \n")

        case .code(let codeKind):
            codeBuffer = CodeBuffer(kind: codeKind)

        case .table, .tableSection, .tableRow, .tableCell:
            openTablePart(kind, tag: tag)

        case .ignored:
            break

        case .paragraph, .list, .listItem, .block:
            openBlock(kind)
        }
    }

    private mutating func openBlock(_ kind: HTMLTag.Kind) {
        switch kind {
        case .paragraph:
            beginBlock(blankLine: true)

        case .list(let ordered):
            openList(ordered: ordered)

        case .listItem:
            openListItem()

        default:
            beginBlock(blankLine: false)
        }
    }

    /// 表のセルの区切り。前のセルと 1 つの空白で区切る（表の中の表など、Markdown の表にしないとき）
    mutating func separateTableCell() {
        guard !output.isAtLineStart else {
            return
        }
        pendingWhitespace.removeAll()
        output.trimTrailingSpaces()
        output.append(" ")
    }

    private mutating func handleClosing(_ tag: HTMLTag) {
        switch HTMLTag.Kind(name: tag.name) {
        case .heading, .emphasis, .link:
            closeInline(matching: tag.name)

        case .paragraph:
            beginBlock(blankLine: true)

        case .list:
            closeList()

        case .listItem, .block:
            beginBlock(blankLine: false)

        case .table, .tableSection, .tableRow, .tableCell:
            closeTablePart(HTMLTag.Kind(name: tag.name))

        case .lineBreak, .code, .ignored:
            break
        }
    }

    /// ブロック要素の境界。開いているインライン要素を閉じ、整形用の空白を捨てて改行（または空行）を入れる
    mutating func beginBlock(blankLine: Bool) {
        closeAllInline()
        pendingWhitespace.removeAll()
        if blankLine {
            output.ensureBlankLine()
        } else {
            output.ensureNewline()
        }
    }

    private mutating func openHeading(level: Int) {
        beginBlock(blankLine: true)
        let markerStart = output.count
        output.append(contentsOf: String(repeating: "#", count: level) + " ")
        inlineStack.append(InlineMarker(tag: "h\(level)", kind: .heading(level), markerStart: markerStart, contentStart: output.count))
    }

    private mutating func openInline(_ kind: InlineMarker.Kind, tag: String) {
        flushPendingWhitespace()
        let markerStart = output.count
        if case .emphasis(let marker) = kind {
            output.append(contentsOf: marker)
        } else {
            output.append("[")
        }
        inlineStack.append(InlineMarker(tag: tag, kind: kind, markerStart: markerStart, contentStart: output.count))
    }

    /// 閉じタグに対応する要素を閉じる。間に開いたままの要素があれば先に閉じる。対応する要素が無ければ何もしない
    private mutating func closeInline(matching tag: String) {
        guard let position = inlineStack.lastIndex(where: { $0.matches(closingTag: tag) }) else {
            return
        }
        flushPendingWhitespace()
        while inlineStack.count > position {
            finish(inlineStack.removeLast())
        }
    }

    mutating func closeAllInline() {
        guard !inlineStack.isEmpty else {
            return
        }
        flushPendingWhitespace()
        while let marker = inlineStack.popLast() {
            finish(marker)
        }
    }

    mutating func finish(_ marker: InlineMarker) {
        let content = output.suffix(from: marker.contentStart)
        let replacement = marker.kind.markdown(content: content)
        output.replaceSuffix(from: marker.markerStart, with: replacement)
        if case .heading = marker.kind {
            output.ensureBlankLine()
        }
    }

    private mutating func openList(ordered: Bool) {
        beginBlock(blankLine: listStack.isEmpty)
        let indent = listStack.last.map { $0.indent + $0.markerWidth } ?? 0
        listStack.append(ListContext(ordered: ordered, indent: indent))
    }

    private mutating func closeList() {
        if !listStack.isEmpty {
            listStack.removeLast()
        }
        beginBlock(blankLine: listStack.isEmpty)
    }

    private mutating func openListItem() {
        if listStack.isEmpty {
            // `<ul>` の無い `<li>` は箇条書きとして扱う
            openList(ordered: false)
        } else {
            beginBlock(blankLine: false)
        }
        let marker = listStack[listStack.count - 1].nextMarker()
        output.append(contentsOf: String(repeating: " ", count: listStack[listStack.count - 1].indent) + marker)
        output.beginListItem()
    }
}
