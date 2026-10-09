import AskHubKit
import SwiftUI

/// 本文の表（`RenderedBody.Table`）を、GitHub と同じく列を揃えた表として描画する。
///
/// ヘッダー行は太字にして背景を付け、行の間に区切り線を引く。セルは折り返す。
/// 列の揃え（`:---:` など）はセルの中の文字の揃えに反映する（iOS / macOS 共通）
struct RenderedTableView: View {
    let table: RenderedBody.Table

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            if hasHeader {
                GridRow {
                    cells(table.header, isHeader: true)
                }
                .background(.quaternary.opacity(0.5))
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                if hasHeader || index > 0 {
                    Divider()
                }
                GridRow {
                    cells(row, isHeader: false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary)
        }
    }

    /// ヘッダーがすべて空の表（`|  |  |`）は、空の行を出さずに本文の行から始める
    private var hasHeader: Bool {
        table.header.contains { !$0.characters.isEmpty }
    }

    private func cells(_ row: [AttributedString], isHeader: Bool) -> some View {
        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
            let alignment = Self.alignment(table.alignments[column])
            Text(cell)
                .bold(isHeader)
                .multilineTextAlignment(alignment.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
        }
    }

    private static func alignment(_ alignment: RenderedBody.ColumnAlignment) -> (text: TextAlignment, frame: Alignment) {
        switch alignment {
        case .leading:
            (.leading, .leading)

        case .center:
            (.center, .center)

        case .trailing:
            (.trailing, .trailing)
        }
    }
}
