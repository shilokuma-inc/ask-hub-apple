import AskHubKit
import SwiftUI

/// 本文（`RenderedBody`）を見出し・段落・箇条書き・コードブロック・表として描画する。
///
/// 質問の詳細とマージ待ちの PR 本文で共通に使う（iOS / macOS 共通。Discussion #128 の Q3）。
/// 太字・斜体・コード・リンクは `Text(AttributedString)` の解釈に任せる。文字は選択できる
struct RenderedBodyView: View {
    let content: RenderedBody

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(content.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: RenderedBody.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level: level))
                .padding(.top, 4)

        case .paragraph(let text):
            Text(text)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItemView(item)
                }
            }

        case .codeBlock(_, let code):
            Text(code)
                .font(.callout.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

        case .table(let table):
            tableView(table)
        }
    }

    /// 表示できる幅が足りれば表、足りなければ行ごとのカードで描画する（`#if os` ではなく幅で切り替える）。
    /// 本文の行が無い表はカードにすると文字が消えるので、いつも表にする
    @ViewBuilder private func tableView(_ table: RenderedBody.Table) -> some View {
        if table.rows.isEmpty {
            RenderedTableView(table: table)
        } else {
            ViewThatFits(in: .horizontal) {
                RenderedTableView(table: table)
                    .frame(minWidth: table.minimumTableWidth, idealWidth: table.minimumTableWidth, maxWidth: .infinity)
                RenderedTableCardsView(table: table)
            }
        }
    }

    private func listItemView(_ item: RenderedBody.ListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.ordinal.map { "\($0)." } ?? "•")
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
                .accessibilityHidden(true)
            // HStack の中の複数 run の Text は run の境目で折り返されることがあるので、幅いっぱいを提案する
            Text(item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(item.depth) * 18)
    }

    /// 見出しのフォント。Form の中で浮かないよう、h1 でも title2 までにとどめる
    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            .title2.bold()

        case 2:
            .title3.bold()

        default:
            .headline
        }
    }
}

#if DEBUG
#Preview {
    Form {
        Section("質問") {
            RenderedBodyView(content: RenderedBody(body: """
                <h3>Q1. 見出し</h3>
                <p>段落に <b>太字</b> と <code>&lt;code&gt;</code> と <a href="https://example.com">リンク</a>。</p>
                <ul><li>項目<ul><li>入れ子</li></ul></li></ul>
                1. 番号
                2. 番号

                ```swift
                let a = 1
                ```

                | 項目 | 値 |
                | --- | :-: |
                | **太字** | `code` |
                | 長い文字のセルは折り返して表示します。長い文字のセルは折り返して表示します。 | [リンク](https://example.com) |
                """))
        }
    }
    .formStyle(.grouped)
}
#endif
