@testable import AskHubKit
import Testing

struct HTMLTableConversionTests {
    private func convert(_ html: String) -> String {
        HTMLMarkdownConverter.convert(html)
    }

    @Test func usesTheadRowAsHeader() {
        let html = """
        <table>
          <thead><tr><td>名前</td><td>数</td></tr></thead>
          <tbody>
            <tr><td>りんご</td><td>1</td></tr>
            <tr><td>みかん</td><td>2</td></tr>
          </tbody>
        </table>
        """
        #expect(convert(html) == "| 名前 | 数 |\n| --- | --- |\n| りんご | 1 |\n| みかん | 2 |")
    }

    @Test func withoutTheadPrefersRowOfThCells() {
        #expect(convert("<table><tr><td>a</td></tr><tr><th>見出し</th></tr></table>") == "| 見出し |\n| --- |\n| a |")
        #expect(convert("<table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table>")
            == "| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    @Test func padsShortRowsAndKeepsEmptyCells() {
        let html = "<table><tr><th>a</th><th>b</th><th>c</th></tr><tr><td>1</td></tr><tr><td></td><td>2</td><td> </td></tr></table>"
        #expect(convert(html) == "| a | b | c |\n| --- | --- | --- |\n| 1 |  |  |\n|  | 2 |  |")
    }

    @Test func convertsAlignAttributeOfHeaderCells() {
        let html = #"<table><tr><th align="left">a</th><th align="CENTER">b</th><th align="right">c</th><th>d</th></tr></table>"#
        #expect(convert(html) == "| a | b | c | d |\n| :--- | :---: | ---: | --- |")
    }

    @Test func escapesPipesAndKeepsCellsOnOneLine() {
        let html = "<table><tr><th>a|b</th><th>x \\| y</th></tr><tr><td>1 行目<br>2 行目\n3 行目</td><td><p>段落</p><p>2 つ目</p></td></tr></table>"
        #expect(convert(html) == "| a\\|b | x \\| y |\n| --- | --- |\n| 1 行目 2 行目 3 行目 | 段落 2 つ目 |")
    }

    @Test func escapesPipeAfterEscapedBackslash() {
        // `\\` はエスケープされた `\` なので、続く `|` はエスケープされていない
        #expect(convert("<table><tr><td>a\\\\|b</td><td>c\\\\\\|d</td></tr></table>") == "| a\\\\\\|b | c\\\\\\|d |\n| --- | --- |")
    }

        @Test func convertsInlineTagsInsideCells() {
        let html = #"<table><tr><th><b>太字</b></th><th><code>a|b</code></th><th><a href="https://example.com">リンク</a></th></tr></table>"#
        #expect(convert(html) == "| **太字** | `a\\|b` | [リンク](https://example.com) |\n| --- | --- | --- |")
    }

    @Test func colspanKeepsSingleCell() {
        let html = #"<table><tr><th>a</th><th>b</th></tr><tr><td colspan="2">結合</td></tr><tr><td rowspan="2">縦</td><td>1</td></tr></table>"#
        #expect(convert(html) == "| a | b |\n| --- | --- |\n| 結合 |  |\n| 縦 | 1 |")
    }

    @Test func nestedTableAndListBecomeTextOfTheCell() {
        let html = "<table><tr><th>外</th></tr><tr><td><table><tr><td>内 1</td><td>内 2</td></tr></table></td></tr>"
            + "<tr><td><ul><li>項目 1</li><li>項目 2</li></ul></td></tr></table>"
        #expect(convert(html) == "| 外 |\n| --- |\n| 内 1 内 2 |\n| - 項目 1 - 項目 2 |")
    }

    @Test func separatesTableFromSurroundingText() {
        #expect(convert("前<table><tr><td>a</td></tr></table>後") == "前\n\n| a |\n| --- |\n\n後")
        #expect(convert("<p>前</p><table><tr><td>a</td></tr></table><table><tr><td>b</td></tr></table>")
            == "前\n\n| a |\n| --- |\n\n| b |\n| --- |")
    }

    @Test func keepsEntitiesForMarkdownParser() {
        // 文字参照は Markdown のパーサーがデコードするので、変換ではデコードしない（二重デコードを防ぐ）
        #expect(convert("<table><tr><td>&lt;b&gt; &amp;amp;</td></tr></table>") == "| &lt;b&gt; &amp;amp; |\n| --- |")
    }

    @Test(arguments: ["<table></table>", "<table><tr></tr></table>", "<table>\n  <tbody>\n  </tbody>\n</table>"])
    func emptyTableOutputsNothing(html: String) {
        #expect(convert(html).isEmpty)
    }

    @Test func strayTableTagsDoNotLoseText() {
        #expect(convert("<td>a</td><td>b</td></tr></table>後") == "a b\n後")
        #expect(convert("<table><tr><td>閉じ忘れ") == "| 閉じ忘れ |\n| --- |")
    }
}
