import Foundation

/// 読んでいる途中の `<table>`
struct HTMLTableContext {
    struct Cell {
        var markdown: String
        let isHeader: Bool
        /// `align` 属性（小文字）
        let alignment: String?
    }

    struct Row {
        var cells: [Cell] = []
        /// `<thead>` の中の行か
        let isInHead: Bool
    }

    /// 開いているセルの、出力の中での始まりの位置と種類
    struct OpenCell {
        let start: Int
        let isHeader: Bool
        let alignment: String?
    }

    var rows: [Row] = []
    var row: Row?
    var cell: OpenCell?
    var isInHead = false
    /// セルの中にある `<table>` の深さ。0 より大きい間は、表のタグを今までどおり文字だけ残す扱いにする
    var nestedDepth = 0
}

// HTML の表を Markdown の表に変換する（Discussion #312 の Q2）。
// セルの中身は通常どおり Markdown に変換して出力に書き、セルが閉じたら取り出して 1 行にまとめる
extension HTMLMarkdownConversion {
    /// Markdown の表として組み立てている最中か（表の外や、セルの中の表では偽）
    private var isBuildingTable: Bool {
        table.map { $0.nestedDepth == 0 } ?? false
    }

    mutating func openTablePart(_ kind: HTMLTag.Kind, tag: HTMLTag) {
        if case .table = kind {
            openTable()
            return
        }
        guard isBuildingTable else {
            // 表の外の `<tr>` `<td>` や、セルの中の表は、今までどおり文字だけ残す
            if case .tableCell = kind {
                separateTableCell()
            } else {
                beginBlock(blankLine: false)
            }
            return
        }
        switch kind {
        case .tableSection(let isHead):
            finishTableRow()
            table?.isInHead = isHead

        case .tableRow:
            finishTableRow()
            startTableRow()

        case .tableCell:
            finishTableCell()
            if table?.row == nil {
                startTableRow()
            }
            pendingWhitespace.removeAll()
            table?.cell = HTMLTableContext.OpenCell(
                start: output.count,
                isHeader: tag.name == "th",
                alignment: tag.attributes["align"]?.lowercased()
            )

        default:
            break
        }
    }

    mutating func closeTablePart(_ kind: HTMLTag.Kind) {
        if case .table = kind {
            closeTable()
            return
        }
        guard isBuildingTable else {
            if case .tableCell = kind {
                return
            }
            beginBlock(blankLine: false)
            return
        }
        switch kind {
        case .tableSection:
            finishTableRow()
            table?.isInHead = false

        case .tableRow:
            finishTableRow()

        case .tableCell:
            finishTableCell()

        default:
            break
        }
    }

    private mutating func openTable() {
        if table != nil {
            // セルの中（またはセルの外）の入れ子の表は、外側の表の文字にする
            table?.nestedDepth += 1
            beginBlock(blankLine: false)
            return
        }
        beginBlock(blankLine: true)
        table = HTMLTableContext()
    }

    private mutating func closeTable() {
        guard var context = table else {
            beginBlock(blankLine: false)
            return
        }
        if context.nestedDepth > 0 {
            context.nestedDepth -= 1
            table = context
            beginBlock(blankLine: false)
            return
        }
        finishTableRow()
        let rows = table?.rows ?? []
        table = nil
        closeAllInline()
        pendingWhitespace.removeAll()
        guard let markdown = Self.markdownTable(rows) else {
            return
        }
        output.ensureBlankLine()
        output.append(contentsOf: markdown)
        output.ensureBlankLine()
    }

    private mutating func finishTableCell() {
        guard let cell = table?.cell else {
            return
        }
        // セルの中で開いたインライン要素だけを閉じる
        flushPendingWhitespace()
        while let marker = inlineStack.last, marker.markerStart >= cell.start {
            finish(inlineStack.removeLast())
        }
        pendingWhitespace.removeAll()
        let content = output.suffix(from: cell.start)
        output.replaceSuffix(from: cell.start, with: [])
        table?.cell = nil
        if table?.row == nil {
            startTableRow()
        }
        table?.row?.cells.append(HTMLTableContext.Cell(
            markdown: Self.singleLineCell(content),
            isHeader: cell.isHeader,
            alignment: cell.alignment
        ))
    }

    private mutating func startTableRow() {
        let isInHead = table?.isInHead ?? false
        table?.row = HTMLTableContext.Row(isInHead: isInHead)
    }

    private mutating func finishTableRow() {
        finishTableCell()
        guard let row = table?.row else {
            return
        }
        table?.row = nil
        if !row.cells.isEmpty {
            table?.rows.append(row)
        }
    }

    /// セルの Markdown を 1 行にする。改行（`<br>` のハードブレークや、セルの中のブロック要素の境界）は空白にまとめ、
    /// 列の区切りと読まれないよう `|` を `\|` にエスケープする（既にエスケープされたものはそのまま）
    static func singleLineCell(_ content: [Character]) -> String {
        var result: [Character] = []
        var previous: Character?
        for char in content {
            if char.isWhitespace {
                if let last = result.last, last != " " {
                    result.append(" ")
                }
            } else {
                if char == "|", previous != "\\" {
                    result.append("\\")
                }
                result.append(char)
            }
            previous = char
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    /// 行を Markdown の表にする。ヘッダーは `<thead>` の行、無ければ `<th>` だけの行、それも無ければ先頭の行。
    /// 列の数はいちばん多い行にそろえ、足りないセルは空にする（`colspan` / `rowspan` はセルを分けない）
    static func markdownTable(_ rows: [HTMLTableContext.Row]) -> String? {
        guard !rows.isEmpty else {
            return nil
        }
        let headerIndex = rows.firstIndex { $0.isInHead }
            ?? rows.firstIndex { $0.cells.allSatisfy(\.isHeader) }
            ?? 0
        var body = rows
        let header = body.remove(at: headerIndex)
        let columnCount = rows.map(\.cells.count).max() ?? 1
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columnCount - cells.count)
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let delimiters = (0..<columnCount).map { column in
            switch column < header.cells.count ? header.cells[column].alignment : nil {
            case "center":
                ":---:"

            case "right":
                "---:"

            case "left":
                ":---"

            default:
                "---"
            }
        }
        let lines = [line(header.cells.map(\.markdown)), line(delimiters)] + body.map { line($0.cells.map(\.markdown)) }
        return lines.joined(separator: "\n")
    }
}
