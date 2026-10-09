import Foundation

/// 質問や PR の本文（Markdown と HTML の混在）を、画面で描画しやすいブロック要素に分けたもの。
///
/// `HTMLMarkdownConverter` で HTML を Markdown に変換したうえで、`AttributedString(markdown:)` の full 解釈と
/// `presentationIntent` を使って見出し・段落・箇条書き・コードブロック・表に分ける（Discussion #128 の決定）。
/// 太字・斜体・コード・リンクは各ブロックの `AttributedString` に `inlinePresentationIntent` / `link` として残る。
///
/// - Markdown の見出し（`### Q1.`）と HTML の見出し（`<h3>`）は同じ `heading` になる
/// - GitHub のコメントと同じく、本文の 1 つの改行も改行として残す
/// - 画像（`![..](..)` と `<img>`）と先頭の目印（HTML コメント）は除く
/// - 解釈に失敗した本文は、文字をそのまま 1 つの段落にする（文字を失わない）
public struct RenderedBody: Sendable, Equatable {
    /// 箇条書きの 1 項目
    public struct ListItem: Sendable, Equatable {
        /// 入れ子の深さ。いちばん外側が 0
        public var depth: Int
        /// 番号付きリストの番号。番号なしのリストでは `nil`
        public var ordinal: Int?
        public var text: AttributedString

        public init(depth: Int, ordinal: Int?, text: AttributedString) {
            self.depth = depth
            self.ordinal = ordinal
            self.text = text
        }
    }

    /// 表の列の揃え（区切り行の `:---:` など）
    public enum ColumnAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    /// 表。ヘッダー行と各行のセルの数は、いつも列の数（`alignments.count`）にそろえる
    public struct Table: Sendable, Equatable {
        public var alignments: [ColumnAlignment]
        /// ヘッダー行のセル。ヘッダーが空の列は空の文字列
        public var header: [AttributedString]
        /// 本文の行。足りないセルは空の文字列で埋める
        public var rows: [[AttributedString]]

        public init(alignments: [ColumnAlignment], header: [AttributedString], rows: [[AttributedString]]) {
            self.alignments = alignments
            self.header = header
            self.rows = rows
        }

        public var columnCount: Int {
            alignments.count
        }

        /// ヘッダー行と本文の行を、セルを ` | ` で区切って 1 行ずつ改行でつなげたもの
        public var plainText: String {
            ([header] + rows)
                .map { $0.map { String($0.characters) }.joined(separator: " | ") }
                .joined(separator: "\n")
        }
    }

    public enum Block: Sendable, Equatable {
        /// 見出し。`level` は 1〜6
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// 箇条書き。入れ子の項目も平らに並べ、`depth` で深さを表す
        case list([ListItem])
        /// コードブロック。`language` はフェンスの言語指定（無ければ `nil`）
        case codeBlock(language: String?, code: String)
        /// 表。セルの太字・コード・リンクは `AttributedString` に残る
        case table(Table)
    }

    public var blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    /// GitHub のコメント本文（Markdown と HTML の混在）から作る
    public init(body: String) {
        self.init(markdown: HTMLMarkdownConverter.convert(body))
    }

    /// Markdown から作る（HTML は解釈しない）
    public init(markdown: String) {
        let source = Self.preservingLineBreaks(markdown)
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks = text.isEmpty ? [] : [.paragraph(AttributedString(text))]
            return
        }
        var builder = BlockBuilder()
        for run in attributed.runs {
            builder.append(run, in: attributed)
        }
        blocks = builder.finish()
    }

    /// すべてのブロックの文字を改行でつなげたもの（テストや要約用）
    public var plainText: String {
        blocks.map { block in
            switch block {
            case .heading(_, let text), .paragraph(let text):
                String(text.characters)

            case .list(let items):
                items.map { String($0.text.characters) }.joined(separator: "\n")

            case .codeBlock(_, let code):
                code

            case .table(let table):
                table.plainText
            }
        }
        .joined(separator: "\n")
    }

    /// 段落の中の 1 つの改行をハードブレーク（行末の空白 2 つ）にして、full 解釈でも改行が残るようにする。
    /// フェンスドコードブロックの中は変えない
    static func preservingLineBreaks(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fence: FenceRun?
        for index in lines.indices {
            let line = lines[index]
            if let run = Self.fenceRun(of: line) {
                if let open = fence {
                    if run.character == open.character, run.length >= open.length, run.isAlone {
                        fence = nil
                    }
                } else {
                    fence = run
                }
                continue
            }
            guard fence == nil,
                  !line.allSatisfy(\.isWhitespace),
                  index + 1 < lines.count,
                  !lines[index + 1].allSatisfy(\.isWhitespace),
                  !line.hasSuffix("  "), !line.hasSuffix("\\") else {
                continue
            }
            lines[index] += "  "
        }
        return lines.joined(separator: "\n")
    }

    /// 行頭（3 つまでの空白を許す）のフェンス（``` か ~~~ が 3 つ以上）
    private struct FenceRun {
        let character: Character
        let length: Int
        /// フェンスの後に文字が無い（閉じフェンスになれる）か
        let isAlone: Bool
    }

    private static func fenceRun(of line: String) -> FenceRun? {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else {
            return nil
        }
        let rest = trimmed.dropFirst(run.count)
        return FenceRun(character: first, length: run.count, isAlone: rest.allSatisfy(\.isWhitespace))
    }
}

/// `AttributedString` の run を、`presentationIntent` の identity でブロックにまとめる
private struct BlockBuilder {
    private enum Current {
        case heading(level: Int, identity: Int, text: AttributedString)
        case paragraph(identity: Int, text: AttributedString)
        /// `itemIdentity` は直近の項目、`paragraphIdentity` はその項目の中の直近の段落（2 つ目の段落で改行を挟むため）
        case list(identity: Int, items: [RenderedBody.ListItem], itemIdentity: Int?, paragraphIdentity: Int?)
        case codeBlock(identity: Int, language: String?, code: String)
        case table(identity: Int, table: RenderedBody.Table)
    }

    private var current: Current?
    private var blocks: [RenderedBody.Block] = []

    mutating func append(_ run: AttributedString.Runs.Run, in attributed: AttributedString) {
        // 画像（`ask-badge` などのバッジを含む）は表示しない（alt も出さない）。
        // 正規表現で先に消すとコードの中の `![alt](url)` まで消えるので、解釈した結果の run で除く
        guard run.imageURL == nil else {
            return
        }
        var piece = AttributedString(attributed[run.range])
        piece.presentationIntent = nil
        let components = run.presentationIntent?.components ?? []

        if let table = Self.tableComponents(components) {
            appendTableCell(piece, table: table)
        } else if let code = components.first(where: { if case .codeBlock = $0.kind { return true } else { return false } }) {
            appendCode(piece, component: code)
        } else if let lists = Self.listComponents(components), !lists.isEmpty {
            appendListItem(piece, components: components, lists: lists)
        } else if let header = components.first(where: { if case .header = $0.kind { return true } else { return false } }),
                  case .header(let level) = header.kind {
            appendHeading(piece, level: level, identity: header.identity)
        } else if components.contains(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) {
            flush()
        } else {
            appendParagraph(piece, identity: components.first?.identity ?? -1)
        }
    }

    mutating func finish() -> [RenderedBody.Block] {
        flush()
        return blocks
    }

    // MARK: - ブロックごとの追加

    private mutating func appendHeading(_ piece: AttributedString, level: Int, identity: Int) {
        if case .heading(let currentLevel, let currentIdentity, var text) = current, currentIdentity == identity {
            text.append(piece)
            current = .heading(level: currentLevel, identity: identity, text: text)
        } else {
            flush()
            current = .heading(level: level, identity: identity, text: piece)
        }
    }

    private mutating func appendParagraph(_ piece: AttributedString, identity: Int) {
        if case .paragraph(let currentIdentity, var text) = current, currentIdentity == identity {
            text.append(piece)
            current = .paragraph(identity: identity, text: text)
        } else {
            flush()
            current = .paragraph(identity: identity, text: piece)
        }
    }

    private mutating func appendCode(_ piece: AttributedString, component: PresentationIntent.IntentType) {
        let language: String? = if case .codeBlock(let hint) = component.kind { hint } else { nil }
        if case .codeBlock(let identity, let currentLanguage, var code) = current, identity == component.identity {
            code += String(piece.characters)
            current = .codeBlock(identity: identity, language: currentLanguage, code: code)
        } else {
            flush()
            current = .codeBlock(identity: component.identity, language: language, code: String(piece.characters))
        }
    }

    /// 表のセルの run なら、表・行・セルの intent を取り出す。表を含むリストの項目でも表として扱う
    private static func tableComponents(_ components: [PresentationIntent.IntentType]) -> TableComponents? {
        var columns: [PresentationIntent.TableColumn]?
        var tableIdentity: Int?
        var rowIndex: Int?
        var columnIndex: Int?
        for component in components {
            switch component.kind {
            case .table(let tableColumns) where tableIdentity == nil:
                columns = tableColumns
                tableIdentity = component.identity

            case .tableHeaderRow where rowIndex == nil:
                rowIndex = 0

            case .tableRow(let index) where rowIndex == nil:
                rowIndex = index

            case .tableCell(let index) where columnIndex == nil:
                columnIndex = index

            default:
                break
            }
        }
        guard let columns, let tableIdentity, let rowIndex, let columnIndex else {
            return nil
        }
        return TableComponents(identity: tableIdentity, columns: columns, rowIndex: rowIndex, columnIndex: columnIndex)
    }

    /// 表のセルの位置。`rowIndex` はヘッダー行が 0、本文の行が 1 から
    private struct TableComponents {
        let identity: Int
        let columns: [PresentationIntent.TableColumn]
        let rowIndex: Int
        let columnIndex: Int
    }

    /// セルの文字を表に足す。空のセル・空の行には run が無いので、位置（行・列の番号）で埋める
    private mutating func appendTableCell(_ piece: AttributedString, table position: TableComponents) {
        var table: RenderedBody.Table
        if case .table(let identity, let currentTable) = current, identity == position.identity {
            table = currentTable
        } else {
            flush()
            let alignments = position.columns.map(Self.alignment)
            table = RenderedBody.Table(alignments: alignments, header: alignments.map { _ in AttributedString() }, rows: [])
        }
        // 区切り行より多いセルは Foundation が落とすが、念のため列を増やして文字を失わない
        while table.columnCount <= position.columnIndex {
            table.alignments.append(.leading)
            table.header.append(AttributedString())
            for row in table.rows.indices {
                table.rows[row].append(AttributedString())
            }
        }
        if position.rowIndex == 0 {
            table.header[position.columnIndex].append(piece)
        } else {
            let row = position.rowIndex - 1
            while table.rows.count <= row {
                table.rows.append(table.alignments.map { _ in AttributedString() })
            }
            table.rows[row][position.columnIndex].append(piece)
        }
        current = .table(identity: position.identity, table: table)
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> RenderedBody.ColumnAlignment {
        switch column.alignment {
        case .center:
            .center

        case .right:
            .trailing

        default:
            .leading
        }
    }

    /// 入れ子の `listItem` / `*List` を、内側から外側の順に取り出す
    private static func listComponents(_ components: [PresentationIntent.IntentType]) -> [PresentationIntent.IntentType]? {
        let lists = components.filter {
            switch $0.kind {
            case .orderedList, .unorderedList, .listItem:
                true

            default:
                false
            }
        }
        return lists.isEmpty ? nil : lists
    }

    private mutating func appendListItem(
        _ piece: AttributedString,
        components: [PresentationIntent.IntentType],
        lists: [PresentationIntent.IntentType]
    ) {
        // いちばん外側のリストが同じなら、同じ箇条書きのブロック
        guard let outermost = lists.last(where: { if case .listItem = $0.kind { return false } else { return true } }),
              let innermostItem = lists.first(where: { if case .listItem = $0.kind { return true } else { return false } }),
              case .listItem(let ordinal) = innermostItem.kind else {
            appendParagraph(piece, identity: components.first?.identity ?? -1)
            return
        }
        let depth = lists.filter { if case .listItem = $0.kind { return true } else { return false } }.count - 1
        let innermostList = lists.first { if case .listItem = $0.kind { return false } else { return true } }
        let isOrdered = if case .orderedList = innermostList?.kind { true } else { false }

        let paragraphIdentity = components.first?.identity
        var items: [RenderedBody.ListItem] = []
        if case .list(let identity, let currentItems, let itemIdentity, let currentParagraph) = current, identity == outermost.identity {
            items = currentItems
            if itemIdentity == innermostItem.identity, !items.isEmpty {
                // 同じ項目の続き。太字などの run の切れ目ならそのままつなげ、2 つ目の段落なら改行を挟む
                var last = items.removeLast()
                if currentParagraph != paragraphIdentity {
                    last.text.append(AttributedString("\n"))
                }
                last.text.append(piece)
                items.append(last)
                current = .list(identity: identity, items: items, itemIdentity: itemIdentity, paragraphIdentity: paragraphIdentity)
                return
            }
        } else {
            flush()
        }
        items.append(RenderedBody.ListItem(depth: depth, ordinal: isOrdered ? ordinal : nil, text: piece))
        current = .list(
            identity: outermost.identity,
            items: items,
            itemIdentity: innermostItem.identity,
            paragraphIdentity: paragraphIdentity
        )
    }

    private mutating func flush() {
        defer { current = nil }
        switch current {
        case .heading(let level, _, let text):
            blocks.append(.heading(level: level, text: Self.trimmed(text)))

        case .paragraph(_, let text):
            let trimmed = Self.trimmed(text)
            if !trimmed.characters.isEmpty {
                blocks.append(.paragraph(trimmed))
            }

        case .list(_, let items, _, _):
            blocks.append(.list(items.map { RenderedBody.ListItem(depth: $0.depth, ordinal: $0.ordinal, text: Self.trimmed($0.text)) }))

        case .codeBlock(_, let language, let code):
            var trimmedCode = code[...]
            while trimmedCode.last?.isNewline == true {
                trimmedCode = trimmedCode.dropLast()
            }
            blocks.append(.codeBlock(language: language, code: String(trimmedCode)))

        case .table(_, var table):
            table.header = table.header.map(Self.trimmed)
            table.rows = table.rows.map { $0.map(Self.trimmed) }
            blocks.append(.table(table))

        case nil:
            break
        }
    }

    /// 前後の空白・改行を取り除く（属性は残す）
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var result = text
        while let first = result.characters.first, first.isWhitespace {
            result.characters.removeFirst()
        }
        while let last = result.characters.last, last.isWhitespace {
            result.characters.removeLast()
        }
        return result
    }
}
