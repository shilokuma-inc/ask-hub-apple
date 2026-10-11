import AskHubKit
import SwiftUI

/// 仮決め一覧の指示とループの返信の履歴と、指示が処理済みか。判定はオーケストレーターと同じ（`DecisionLogHistory`）。
/// 信用する author 以外のコメントも、指示として扱わないことを示したうえでデータとして出す
struct DecisionLogHistorySection: View {
    let model: DecisionLogHistoryModel
    let inbox: InboxModel

    var body: some View {
        Section {
            summary
            ForEach(model.rows) { row in
                rowView(row)
            }
            Button("履歴を更新") {
                Task { await model.load(using: inbox) }
            }
            .disabled(model.isLoading)
        } header: {
            Text("指示と返信の履歴")
        } footer: {
            Text("ループは返信の先頭に目印を置きます。最後のループの返信（または閉じたときのコメント）より後にある指示が未処理です。信用する author 以外のコメントは指示として扱いません")
        }
    }

    @ViewBuilder private var summary: some View {
        switch model.state {
        case .idle, .loading:
            // 取り直しの間も、進んでいることが分かるようにする
            ProgressView()
                .frame(maxWidth: .infinity)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)

        case .loaded:
            if model.rows.isEmpty {
                Text("（まだコメントがありません）")
                    .foregroundStyle(.secondary)
            } else if model.unprocessedCount > 0 {
                Label(
                    "未処理の指示が \(model.unprocessedCount) 件あります。ループの次の周回で処理されます（ループが止まっていれば、オーケストレーターが再開します）",
                    systemImage: "clock"
                )
                .foregroundStyle(.orange)
            } else {
                Label("未処理の指示はありません", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rowView(_ row: DecisionLogHistoryModel.Row) -> some View {
        let comment = row.entry.comment
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                kindLabel(row.entry.kind)
                Spacer()
                if let createdAt = comment.createdAt {
                    Text(createdAt, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(comment.author.map { "@\($0)" } ?? "（削除されたユーザー）")
                .font(.caption)
                .foregroundStyle(.secondary)
            if row.renderedBody.blocks.isEmpty {
                Text("（本文がありません）")
                    .foregroundStyle(.secondary)
            } else {
                RenderedBodyView(content: row.renderedBody)
            }
            if let url = comment.url {
                Link("GitHub で開く", destination: url)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func kindLabel(_ kind: DecisionLogHistory.Kind) -> some View {
        switch kind {
        case .instruction(isProcessed: true):
            Label("指示・処理済み", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)

        case .instruction(isProcessed: false):
            Label("指示・未処理", systemImage: "clock")
                .foregroundStyle(.orange)

        case .reply:
            Label("ループの返信", systemImage: "arrowshape.turn.up.left")
                .foregroundStyle(.tint)

        case .close:
            Label("閉じたときのコメント", systemImage: "lock")
                .foregroundStyle(.secondary)

        case .untrusted:
            Label("信用外（指示として扱わない）", systemImage: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
        }
    }
}
