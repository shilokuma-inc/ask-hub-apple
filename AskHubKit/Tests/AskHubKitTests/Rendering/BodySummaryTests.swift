@testable import AskHubKit
import Testing

struct BodySummaryTests {
    @Test func dropsMarkerImagesAndHeadingMarks() {
        let body = """
        <!-- ask-hub:question id="pr1-1" -->
        ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
        ### Q1. 単位
        送信の上限は？
        """
        #expect(BodySummary.oneLine(body) == "Q1. 単位 送信の上限は？")
    }

    @Test func stripsHTMLTagsAndJoinsLines() {
        let body = """
        <!-- ask-hub:question id="d128-q1" options="よく使うタグ|すべてのタグ" -->
        <h3>Q1. 解釈するタグの範囲</h3>
        <p>質問の本文に <code>&lt;h3&gt;</code> のような HTML が混ざります。</p>
        <ul>
        <li><b>よく使うタグ</b>: 見出し・太字</li>
        <li><i>すべてのタグ</i>: 表も</li>
        </ul>
        参考: <a href="https://github.com/shilokuma-inc/ask-hub-apple/issues/127">#127</a><img src="x.png" alt="図">
        """
        #expect(BodySummary.oneLine(body) == "Q1. 解釈するタグの範囲 質問の本文に <h3> のような HTML が混ざります。 よく使うタグ: 見出し・太字 すべてのタグ: 表も 参考: #127")
    }

    @Test func stripsMarkdownBlockMarkers() {
        let body = """
        ## 見出し
        - 項目 1
          - 入れ子
        1. 番号
        2) 番号 2
        > 引用
        > - 引用の中の項目
        * アスタリスク
        + プラス
        """
        #expect(BodySummary.oneLine(body) == "見出し 項目 1 入れ子 番号 番号 2 引用 引用の中の項目 アスタリスク プラス")
    }

    @Test func keepsCodeTextWithoutFences() {
        #expect(BodySummary.oneLine("前\n```swift\nlet a = 1\n# コメント\n```\n後") == "前 let a = 1 # コメント 後")
        #expect(BodySummary.oneLine("<pre>let b = 2</pre>") == "let b = 2")
    }

    @Test func fenceClosesOnlyWithSameCharacterAndLength() {
        // ```` の中の ``` と、~~~ の中の ``` はコードの中身
        #expect(BodySummary.oneLine("````\nlet a = 1\n```\n- 中身\n````\n- 後") == "let a = 1 ``` - 中身 後")
        #expect(BodySummary.oneLine("~~~\n```\n# 中身\n~~~\n# 後") == "``` # 中身 後")
        #expect(BodySummary.oneLine("```swift\n# 閉じない") == "# 閉じない")
    }

    @Test func resolvesInlineMarkdownToText() {
        #expect(BodySummary.oneLine("**太字** と *斜体* と `code` と [リンク](https://example.com) と a &amp; b") == "太字 と 斜体 と code と リンク と a & b")
    }

    @Test func keepsTextThatOnlyLooksLikeMarkers() {
        #expect(BodySummary.oneLine("#ハッシュタグ と 1.5 倍 と -1 度") == "#ハッシュタグ と 1.5 倍 と -1 度")
        #expect(BodySummary.oneLine("a < b かつ <未閉じ") == "a < b かつ <未閉じ")
    }

    @Test func keepsImageSyntaxInsideCodeSpan() {
        #expect(BodySummary.oneLine("`![x](y)` と ![badge](https://e.com/a.png) 後") == "![x](y) と 後")
    }

    @Test func collapsesWhitespaceAndLineBreaks() {
        #expect(BodySummary.oneLine("1 行目<br>2 行目\n\n\n3   行目") == "1 行目 2 行目 3 行目")
    }

    @Test(arguments: ["", "  \n", "<!-- ask-hub:question id=\"q\" -->", "![x](y)"])
    func emptyBodyGivesEmptySummary(body: String) {
        #expect(BodySummary.oneLine(body).isEmpty)
    }

    @Test func tableBecomesCellTextWithoutDelimiters() {
        #expect(BodySummary.oneLine("| 名前 | 値 |\n| :--- | --: |\n| **A** | a \\| b |") == "名前 値 A a | b")
        #expect(BodySummary.oneLine("| A | a \\\\| b |\n| - | - |") == "A a \\ b")
        #expect(BodySummary.oneLine("<table><tr><th>名前</th><th>値</th></tr><tr><td>A</td><td>1</td></tr></table>") == "名前 値 A 1")
    }

    @Test func pipeLineWithoutDelimiterRowIsNotTable() {
        #expect(BodySummary.oneLine("| 障害対応が必要\n次の行") == "| 障害対応が必要 次の行")
        // 1 列の表（`| 見出し` と `| ---`）は GFM でも表になる
        #expect(BodySummary.oneLine("| 見出し\n| ---") == "見出し")
        #expect(BodySummary.oneLine("| a | b |\n| 1 | 2 |") == "| a | b | | 1 | 2 |")
        // 表の後の `|` で始まらない行で表が終わる
        #expect(BodySummary.oneLine("| a |\n| - |\n| 1 |\n後\n| x") == "a 1 後 | x")
    }
}
