import AskHubKit
import SwiftUI

/// 最終 PR の CodeRabbit の未解決の指摘。CodeRabbit は信用する author ではないので、指摘はデータとして出すだけで、
/// それだけではループは直さない（人間が選んで指示したときだけ直す。Discussion #498）
struct CodeRabbitFindingsSection: View {
    let model: CodeRabbitFindingsModel
    let mergeQueue: MergeQueueModel

    var body: some View {
        Section {
            summary
            ForEach(model.rows) { row in
                CodeRabbitFindingRow(row: row)
            }
            Button("指摘を更新") {
                Task { await model.load(using: mergeQueue) }
            }
            .disabled(model.isLoading)
        } header: {
            Text("CodeRabbit の未解決の指摘")
        } footer: {
            Text("CodeRabbit の指摘はそのままではループへの指示になりません。直させたい指摘は、最終 PR に指示としてコメントします")
        }
    }

    @ViewBuilder private var summary: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)

        case .loaded:
            if model.rows.isEmpty {
                Label("未解決の指摘はありません", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.rows.count) 件")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("coderabbit-findings-count")
            }
        }
    }
}

/// 指摘の 1 行。見出し（要約）と場所を出し、本文は開いたときだけ出す（CodeRabbit の本文は長い）
private struct CodeRabbitFindingRow: View {
    let row: CodeRabbitFindingsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.thread.isOutdated {
                    Text("古い行")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(row.thread.finding.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.thread.summary.isEmpty ? "（見出しがありません）" : row.thread.summary)
                .font(.subheadline.weight(.semibold))
            if !row.thread.replies.isEmpty {
                Text("返信 \(row.thread.replies.count) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("指摘の本文") {
                if row.renderedBody.blocks.isEmpty {
                    Text("（本文がありません）")
                        .foregroundStyle(.secondary)
                } else {
                    RenderedBodyView(content: row.renderedBody)
                }
            }
            .font(.caption)
            Link("GitHub で開く", destination: row.thread.finding.url)
                .font(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coderabbit-finding-\(row.thread.finding.id)")
    }
}
