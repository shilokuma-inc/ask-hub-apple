@testable import AskHubKit
import Testing

struct HTMLMarkdownConverterTests {
    private func convert(_ html: String) -> String {
        HTMLMarkdownConverter.convert(html)
    }

    // MARK: - 見出し・段落・改行

    @Test func convertsHeadings() {
        #expect(convert("<h1>A</h1><h3>Q2. 見出し</h3><h6>F</h6>") == "# A\n\n### Q2. 見出し\n\n###### F")
    }

    @Test func headingIsSingleLine() {
        #expect(convert("<h3>Q2.\n見出し</h3>本文") == "### Q2. 見出し\n\n本文")
        #expect(convert("<h2>  </h2>本文") == "本文")
    }

    @Test func removesLeadingQuestionMarkerAndKeepsMarkdownHeading() {
        let body = """
        <!-- ask-hub:question id="d12-q3" options="24時間|1時間" -->
        ### Q3. レート制限の単位
        送信の上限をどの単位で数えますか？
        """
        #expect(convert(body) == "### Q3. レート制限の単位\n送信の上限をどの単位で数えますか？")
    }

    @Test func paragraphsAreSeparatedByBlankLine() {
        #expect(convert("<p>一つ目</p><p>二つ目</p>") == "一つ目\n\n二つ目")
        #expect(convert("<p>\n    インデント付き\n</p>") == "インデント付き")
    }

    @Test func lineBreakBecomesHardBreak() {
        #expect(convert("一行目<br>二行目<br/>三行目") == "一行目  \n二行目  \n三行目")
    }

    @Test func plainMarkdownPassesThrough() {
        let markdown = """
        ### Q1. 見出し

        - 項目 1
          - 入れ子
        - 項目 2

        本文に `code` と **太字**。
        """
        #expect(convert(markdown) == markdown)
    }

    // MARK: - インライン

    @Test func convertsEmphasis() {
        #expect(convert("<b>太字</b>と<strong>強調</strong>、<i>斜体</i>と<em>強調</em>") == "**太字**と**強調**、*斜体*と*強調*")
    }

    @Test func movesWhitespaceOutsideEmphasisMarkers() {
        #expect(convert("a<b> 太字 </b>b") == "a **太字** b")
        #expect(convert("a<b></b>b") == "ab")
    }

    @Test func convertsLinks() {
        #expect(convert(#"<a href="https://example.com/a">例</a>"#) == "[例](https://example.com/a)")
        #expect(convert(#"<a href='HTTP://example.com'>例</a>"#) == "[例](HTTP://example.com)")
        #expect(convert(#"<a href="https://example.com/"></a>"#) == "[https://example.com/](https://example.com/)")
        #expect(convert(#"<a href="https://example.com/a b">例</a>"#) == "[例](<https://example.com/a b>)")
    }

    @Test(arguments: [
        #"<a href="javascript:alert(1)">危険</a>"#,
        #"<a href="data:text/html,x">危険</a>"#,
        #"<a href="ftp://example.com">危険</a>"#,
        #"<a href="mailto:a@example.com">危険</a>"#,
        #"<a href="/relative">危険</a>"#,
        #"<a href="">危険</a>"#,
        #"<a>危険</a>"#,
        #"<a href="https://example.com/<x>">危険</a>"#
    ])
    func linksWithoutHTTPSchemeKeepOnlyText(html: String) {
        #expect(convert(html) == "危険")
    }

    @Test func dropsImagesIncludingAlt() {
        #expect(convert(#"前<img src="https://example.com/a.png" alt="badge">後"#) == "前後")
        #expect(convert(#"前<img src="x.png" alt="a > b" />後"#) == "前後")
    }

    // MARK: - 箇条書き

    @Test func convertsLists() {
        let html = """
        <ul>
          <li>りんご</li>
          <li>みかん</li>
        </ul>
        <ol>
          <li>一番</li>
          <li>二番</li>
        </ol>
        """
        #expect(convert(html) == "- りんご\n- みかん\n\n1. 一番\n2. 二番")
    }

    @Test func nestedListsAreIndented() {
        let html = "<ol><li>親<ul><li>子 A</li><li>子 B</li></ul></li><li>親 2</li></ol>"
        #expect(convert(html) == "1. 親\n   - 子 A\n   - 子 B\n2. 親 2")
    }

    @Test func listItemCanContainParagraphAndEmphasis() {
        #expect(convert("<ul><li><p>段落</p></li><li><b>太字</b> の項目</li></ul>") == "- 段落\n\n- **太字** の項目")
        #expect(convert("<li>単独</li>") == "- 単独")
    }

    // MARK: - コード

    @Test func convertsInlineCode() {
        #expect(convert("値は <code>a &lt; b</code> です") == "値は `a < b` です")
        #expect(convert("<code>`tick`</code>") == "`` `tick` ``")
        #expect(convert("<code><b>x</b></code>") == "`x`")
        #expect(convert("<code></code>").isEmpty)
    }

    @Test func convertsPreformattedBlocks() {
        let html = "前<pre><code class=\"language-swift\">\nlet a = 1\n\nprint(&quot;a&quot;)\n</code></pre>後"
        #expect(convert(html) == "前\n\n```\nlet a = 1\n\nprint(\"a\")\n```\n\n後")
    }

    @Test func preformattedBlockUsesLongerFenceWhenContentHasBackticks() {
        #expect(convert("<pre>```\nx\n```</pre>") == "````\n```\nx\n```\n````")
    }

    @Test func doesNotInterpretTagsInsideMarkdownCode() {
        #expect(convert("`<b>x</b>` と <b>y</b>") == "`<b>x</b>` と **y**")
        #expect(convert("``a ` <i>b</i>`` と <i>c</i>") == "``a ` <i>b</i>`` と *c*")
        let fenced = "```html\n<h3>そのまま</h3>\n&amp;\n```\n<h3>見出し</h3>"
        #expect(convert(fenced) == "```html\n<h3>そのまま</h3>\n&amp;\n```\n\n### 見出し")
        #expect(convert("~~~\n<b>x</b>\n~~~") == "~~~\n<b>x</b>\n~~~")
    }

    @Test func unclosedMarkdownCodeIsLiteral() {
        #expect(convert("`<b>x</b>") == "`**x**")
        #expect(convert("```\n<b>x</b>") == "```\n<b>x</b>")
    }

    // MARK: - エンティティ

    @Test func leavesEntitiesOutsideCodeForMarkdownParser() {
        #expect(convert("a &lt; b &amp;&amp; c &gt; d &#39;e&#39;") == "a &lt; b &amp;&amp; c &gt; d &#39;e&#39;")
    }

    @Test func decodesEntities() {
        let encoded = "&lt;b&gt; &amp; &quot;q&quot; &apos;a&apos;&nbsp;&#65;&#x42;&#X43;"
        #expect(HTMLMarkdownConverter.decodeEntities(encoded) == "<b> & \"q\" 'a'\u{00A0}ABC")
        #expect(HTMLMarkdownConverter.decodeEntities("&unknown; &amp &#; &#0; &#xZZ; & ;") == "&unknown; &amp &#; &#0; &#xZZ; & ;")
    }

    // MARK: - その他のタグ

    @Test func stripsUnknownTagsAndKeepsText() {
        #expect(convert(#"<span class="x">文字</span><kbd>⌘</kbd><del>消</del>"#) == "文字⌘消")
        #expect(convert("<details><summary>概要</summary>中身</details>") == "概要\n中身")
    }

    @Test func tableBecomesTextOnly() {
        let html = "<table><tr><th>名前</th><th>値</th></tr><tr><td>A</td><td>1</td></tr></table>"
        #expect(convert(html) == "名前 値\nA 1")
    }

    @Test func removesHTMLComments() {
        #expect(convert("前<!-- コメント -->後") == "前後")
        #expect(convert("前<!-- 複数\n行 -->後") == "前後")
    }

    @Test func doesNotLoseTextOnBrokenHTML() {
        #expect(convert("<b>閉じ忘れ") == "**閉じ忘れ**")
        #expect(convert("<b><i>崩れ</b></i>た") == "***崩れ***た")
        #expect(convert("</b>閉じだけ</p>") == "閉じだけ")
        #expect(convert("a < b かつ b > a") == "a < b かつ b > a")
        #expect(convert("<3 と <未閉じ") == "<3 と <未閉じ")
        #expect(convert("<!-- 閉じていないコメント") == "<!-- 閉じていないコメント")
        #expect(convert(#"<a href="https://example.com/x>文字"#) == #"<a href="https://example.com/x>文字"#)
        #expect(convert("<pre>閉じていない") == "```\n閉じていない\n```")
        #expect(convert("<code>閉じていない") == "`閉じていない`")
        #expect(convert("<ul><li>a<li>b</ul>") == "- a\n- b")
        #expect(convert("").isEmpty)
    }

    @Test func normalizesLineEndings() {
        #expect(convert("一行目\r\n二行目\r三行目") == "一行目\n二行目\n三行目")
    }

    @Test func convertsTypicalGitHubQuestion() {
        let body = """
        <!-- ask-hub:question id="d128-q1" options="よく使うタグ|全部" -->
        <h3>Q1. 解釈するタグの範囲</h3>
        <p>どこまで解釈しますか？ <b>詳細</b> は <a href="https://github.com/shilokuma-inc/ask-hub-apple/issues/127">#127</a> を参照。</p>
        <ul>
        <li><code>&lt;h3&gt;</code> など</li>
        <li>表は文字だけ</li>
        </ul>
        ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
        """
        let expected = """
        ### Q1. 解釈するタグの範囲

        どこまで解釈しますか？ **詳細** は [#127](https://github.com/shilokuma-inc/ask-hub-apple/issues/127) を参照。

        - `<h3>` など
        - 表は文字だけ

        ![ask-badge](https://img.shields.io/badge/review-ask-yellowgreen.svg)
        """
        #expect(convert(body) == expected)
    }
}
