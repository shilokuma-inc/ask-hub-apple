@testable import AskHubKit
import Foundation
import Testing

struct RenderedBodyTests {
    private func text(_ block: RenderedBody.Block) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text):
            String(text.characters)

        case .list(let items):
            items.map { String($0.text.characters) }.joined(separator: "|")

        case .codeBlock(_, let code):
            code
        }
    }

    @Test func splitsMarkdownIntoBlocks() throws {
        let body = RenderedBody(markdown: """
        ### Q1. 見出し

        段落です。

        - りんご
        - みかん

        ```swift
        let a = 1
        ```
        """)
        #expect(body.blocks.count == 4)
        guard case .heading(let level, _) = body.blocks[0] else {
            Issue.record("見出しではない")
            return
        }
        #expect(level == 3)
        #expect(text(body.blocks[0]) == "Q1. 見出し")
        #expect(text(body.blocks[1]) == "段落です。")
        #expect(text(body.blocks[2]) == "りんご|みかん")
        #expect(body.blocks[3] == .codeBlock(language: "swift", code: "let a = 1"))
    }

    @Test func htmlAndMarkdownHeadingsBecomeTheSameBlock() {
        let html = RenderedBody(body: "<h3>Q1. 見出し</h3>\n本文")
        let markdown = RenderedBody(body: "### Q1. 見出し\n本文")
        #expect(html == markdown)
        #expect(html.blocks.count == 2)
        #expect(text(html.blocks[0]) == "Q1. 見出し")
    }

    @Test func removesLeadingMarkerAndImages() {
        let body = RenderedBody(body: """
        <!-- ask-hub:question id="pr34-1" options="A|B" -->
        ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
        新しい Product ID を登録してよいですか？ <img src="x.png" alt="図">
        """)
        #expect(body.blocks.count == 1)
        #expect(text(body.blocks[0]) == "新しい Product ID を登録してよいですか？")
    }

    @Test func keepsImageSyntaxInsideCode() {
        let body = RenderedBody(markdown: "`![x](y)` と\n\n```\n![fence](z)\n```\n\n![removed](https://e.com/a.png)")
        #expect(body.blocks.count == 2)
        #expect(text(body.blocks[0]) == "![x](y) と")
        #expect(body.blocks[1] == .codeBlock(language: nil, code: "![fence](z)"))
    }

    @Test func keepsSingleLineBreaksInsideParagraph() {
        let body = RenderedBody(body: "1 行目\n2 行目<br>3 行目")
        #expect(body.blocks.count == 1)
        #expect(text(body.blocks[0]) == "1 行目\n2 行目\n3 行目")
    }

    @Test func keepsInlineStylesAndLinks() throws {
        let body = RenderedBody(body: "<b>太字</b> と *斜体* と <code>code</code> と <a href=\"https://example.com\">リンク</a>")
        #expect(body.blocks.count == 1)
        guard case .paragraph(let paragraph) = body.blocks[0] else {
            Issue.record("段落ではない")
            return
        }
        #expect(String(paragraph.characters) == "太字 と 斜体 と code と リンク")
        let runs = paragraph.runs.map { (String(paragraph[$0.range].characters), $0.inlinePresentationIntent, $0.link) }
        #expect(runs.contains { $0.0 == "太字" && $0.1 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == "斜体" && $0.1 == .emphasized })
        #expect(runs.contains { $0.0 == "code" && $0.1 == .code })
        #expect(runs.contains { $0.0 == "リンク" && $0.2 == URL(string: "https://example.com") })
        #expect(paragraph.runs.allSatisfy { $0.presentationIntent == nil })
    }

    @Test func nestedAndOrderedLists() {
        let body = RenderedBody(body: "<ol><li>親<ul><li>子</li></ul></li><li>親 2</li></ol>\n\n- 別のリスト")
        #expect(body.blocks.count == 2)
        guard case .list(let items) = body.blocks[0] else {
            Issue.record("箇条書きではない")
            return
        }
        #expect(items.map(\.depth) == [0, 1, 0])
        #expect(items.map(\.ordinal) == [1, nil, 2])
        #expect(items.map { String($0.text.characters) } == ["親", "子", "親 2"])
        #expect(text(body.blocks[1]) == "別のリスト")
    }

    @Test func listItemWithInlineStylesStaysOneLine() {
        let body = RenderedBody(body: "<ul><li><b>太字</b>: 説明 <code>code</code> 末尾</li></ul>\n- **強調** と `c` と [l](https://e.com)")
        guard case .list(let items) = body.blocks.first else {
            Issue.record("箇条書きではない")
            return
        }
        #expect(items.map { String($0.text.characters) } == ["太字: 説明 code 末尾", "強調 と c と l"])
    }

    @Test func listItemWithTwoParagraphsStaysOneItem() {
        let body = RenderedBody(markdown: "- 1 つ目\n\n  続き\n- 2 つ目")
        guard case .list(let items) = body.blocks.first else {
            Issue.record("箇条書きではない")
            return
        }
        #expect(items.map { String($0.text.characters) } == ["1 つ目\n続き", "2 つ目"])
    }

    @Test func codeBlockKeepsLineBreaksAndIgnoresTags() {
        let body = RenderedBody(body: "<pre><code>&lt;b&gt;\n\nx</code></pre>\n```\n<i>そのまま</i>\n```")
        #expect(body.blocks == [
            .codeBlock(language: nil, code: "<b>\n\nx"),
            .codeBlock(language: nil, code: "<i>そのまま</i>")
        ])
    }

    @Test func blockQuoteAndThematicBreakDoNotLoseText() {
        let body = RenderedBody(markdown: "> 引用\n\n---\n\n最後")
        #expect(body.plainText == "引用\n最後")
    }

    @Test func plainTextJoinsBlocks() {
        let body = RenderedBody(body: "<h3>Q</h3><p>a</p><ul><li>b</li></ul><pre>c</pre>")
        #expect(body.plainText == "Q\na\nb\nc")
    }

    @Test(arguments: ["", "   \n\n", "<!-- only a comment -->"])
    func emptyBodyHasNoBlocks(source: String) {
        #expect(RenderedBody(body: source).blocks.isEmpty)
    }

    @Test func brokenInputDoesNotLoseText() {
        let body = RenderedBody(body: "<b>閉じ忘れ [リンク](https://example.com\n```\n閉じないフェンス\n<ul><li>項目")
        #expect(body.plainText.contains("閉じ忘れ"))
        #expect(body.plainText.contains("閉じないフェンス"))
        #expect(body.plainText.contains("項目"))
    }

    @Test func preservingLineBreaksSkipsFences() {
        let source = "a\nb\n```\nc\nd\n```\ne\n\nf"
        // フェンスの中は変えない。フェンスの直前の行に付く空白 2 つは無害
        #expect(RenderedBody.preservingLineBreaks(source) == "a  \nb  \n```\nc\nd\n```\ne\n\nf")
    }
}
