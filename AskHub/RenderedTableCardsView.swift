import AskHubKit
import SwiftUI

/// 本文の表（`RenderedBody.Table`）を、狭い幅向けに 1 行 = 1 枚のカードで描画する。
///
/// 先頭の列の値をカードの見出しにし、残りの列を「ヘッダー: 値」で縦に並べる（Discussion #312 の Q1）。
/// ヘッダーが空の列は値だけを出し、値が空の列は出さない。すべてのセルが空の行はカードにしない
struct RenderedTableCardsView: View {
    let table: RenderedBody.Table

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cardRows.enumerated()), id: \.offset) { _, row in
                card(row)
            }
        }
    }

    private var cardRows: [[AttributedString]] {
        table.rows.filter { row in row.contains { !$0.characters.isEmpty } }
    }

    private func card(_ row: [AttributedString]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = row.first, !title.characters.isEmpty {
                Text(title)
                    .bold()
            }
            ForEach(Array(row.indices.dropFirst()), id: \.self) { column in
                if !row[column].characters.isEmpty {
                    field(header: table.header[column], value: row[column])
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func field(header: AttributedString, value: AttributedString) -> some View {
        // ヘッダーと値を 1 つの Text にして、長い値も見出しの後ろから続けて折り返す
        let label = header.characters.isEmpty ? Text("") : Text(header + AttributedString(": ")).foregroundStyle(.secondary)
        return (label + Text(value))
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension RenderedBody.Table {
    /// 表として描画するのに要る幅。これより狭いと、行ごとのカードで描画する
    var minimumTableWidth: CGFloat {
        CGFloat(columnCount) * 120
    }
}
