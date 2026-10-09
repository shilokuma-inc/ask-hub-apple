@testable import AskHubKit
import Foundation
import Testing

struct RenderedBodyTableTests {
    private func cells(_ row: [AttributedString]) -> [String] {
        row.map { String($0.characters) }
    }

    private func tableBlock(_ block: RenderedBody.Block?) -> RenderedBody.Table? {
        guard case .table(let table) = block else {
            Issue.record("表ではない: \(String(describing: block))")
            return nil
        }
        return table
    }

    @Test func splitsTableIntoHeaderRowsAndAlignments() throws {
        let body = RenderedBody(markdown: """
        | 名前 | 数 | 備考 |
        | :--- | :-: | --: |
        | りんご | 1 | 赤い |
        | みかん | 2 | 甘い |
        """)
        #expect(body.blocks.count == 1)
        let table = try #require(tableBlock(body.blocks.first))
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(cells(table.header) == ["名前", "数", "備考"])
        #expect(table.rows.map(cells) == [["りんご", "1", "赤い"], ["みかん", "2", "甘い"]])
    }

    @Test func alignmentDefaultsToLeading() throws {
        let body = RenderedBody(markdown: "| a | b |\n| --- | --- |\n| 1 | 2 |")
        let table = try #require(tableBlock(body.blocks.first))
        #expect(table.alignments == [.leading, .leading])
    }

    @Test func padsMissingAndEmptyCells() throws {
        let body = RenderedBody(markdown: """
        | a | | c |
        | - | - | - |
        | 1 |
        | | | |
        | 4 | 5 | 6 | 7 |
        """)
        let table = try #require(tableBlock(body.blocks.first))
        #expect(table.columnCount == 3)
        #expect(cells(table.header) == ["a", "", "c"])
        // 空の行にも行の番号があるので、行は詰めない。区切り行より多いセルは Markdown の仕様どおり落ちる
        #expect(table.rows.map(cells) == [["1", "", ""], ["", "", ""], ["4", "5", "6"]])
    }

    @Test func emptyHeaderKeepsColumns() throws {
        let body = RenderedBody(markdown: "|  |  |\n| - | - |\n| x | y |")
        let table = try #require(tableBlock(body.blocks.first))
        #expect(cells(table.header) == ["", ""])
        #expect(table.rows.map(cells) == [["x", "y"]])
    }

    @Test func keepsInlineStylesInsideCells() throws {
        let body = RenderedBody(markdown: "| **太字** と `code` | [リンク](https://example.com) |\n| - | - |\n| *斜体* | a \\| b |")
        let table = try #require(tableBlock(body.blocks.first))
        #expect(cells(table.header) == ["太字 と code", "リンク"])
        #expect(table.rows.map(cells) == [["斜体", "a | b"]])
        let first = table.header[0]
        let runs = first.runs.map { (String(first[$0.range].characters), $0.inlinePresentationIntent) }
        #expect(runs.contains { $0.0 == "太字" && $0.1 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == "code" && $0.1 == .code })
        #expect(table.header[1].runs.contains { $0.link == URL(string: "https://example.com") })
        #expect(table.header.allSatisfy { $0.runs.allSatisfy { $0.presentationIntent == nil } })
    }

    @Test func separatesTableFromSurroundingBlocks() throws {
        let body = RenderedBody(markdown: """
        ### 見出し
        前の段落
        | a | b |
        | - | - |
        | 1 | 2 |

        後の段落
        """)
        #expect(body.blocks.count == 4)
        guard case .heading = body.blocks[0], case .paragraph(let before) = body.blocks[1],
              case .paragraph(let after) = body.blocks[3] else {
            Issue.record("区切りが違う: \(body.blocks)")
            return
        }
        #expect(String(before.characters) == "前の段落")
        #expect(String(after.characters) == "後の段落")
        let table = try #require(tableBlock(body.blocks[2]))
        #expect(table.rows.map(cells) == [["1", "2"]])
    }

    @Test func consecutiveTablesStaySeparate() {
        let body = RenderedBody(markdown: "| a |\n| - |\n| 1 |\n\n| b |\n| - |\n| 2 |")
        #expect(body.blocks.count == 2)
        #expect(body.plainText == "a\n1\nb\n2")
    }

    @Test func plainTextKeepsEveryCell() {
        let body = RenderedBody(body: "前\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n後")
        #expect(body.plainText == "前\na | b\n1 | 2\n後")
    }

    @Test func tableInsideListItemBecomesTable() throws {
        let body = RenderedBody(markdown: "- 項目\n\n  | a | b |\n  | - | - |\n  | 1 | 2 |")
        #expect(body.blocks.count == 2)
        #expect(body.plainText == "項目\na | b\n1 | 2")
        let table = try #require(tableBlock(body.blocks.last))
        #expect(table.rows.map(cells) == [["1", "2"]])
    }

    @Test func withoutDelimiterRowStaysParagraph() {
        let body = RenderedBody(markdown: "| a | b |\n| 1 | 2 |")
        #expect(body.blocks.count == 1)
        guard case .paragraph = body.blocks.first else {
            Issue.record("段落ではない")
            return
        }
        #expect(body.plainText.contains("| a | b |"))
    }
}
