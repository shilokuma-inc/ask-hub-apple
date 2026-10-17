import AskHubKit
import SwiftUI

/// 最終 PR の CodeRabbit の未解決の指摘。CodeRabbit は信用する author ではないので、指摘はデータとして出すだけで、
/// それだけではループは直さない（人間が選んで指示したときだけ直す。Discussion #498）
struct CodeRabbitFindingsSection: View {
    let model: CodeRabbitFindingsModel
    let mergeQueue: MergeQueueModel
    /// 「ループに直させる」を押した指摘（指示のシートを出す）
    @State private var selected: CodeRabbitFindingsModel.Row?

    var body: some View {
        Section {
            summary
            ForEach(model.rows) { row in
                CodeRabbitFindingRow(row: row, instructedURL: model.instructed[row.id]) {
                    selected = row
                }
            }
            Button("指摘を更新") {
                Task { await model.load(using: mergeQueue) }
            }
            .disabled(model.isLoading)
        } header: {
            Text("CodeRabbit の未解決の指摘")
        } footer: {
            Text("CodeRabbit の指摘はそのままではループへの指示になりません。「ループに直させる」を押すと、その指摘を直す指示を最終 PR にコメントします（1 件ずつ）")
        }
        .sheet(item: $selected) { row in
            FinalInstructionSheet(row: row, model: model, mergeQueue: mergeQueue)
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

/// 指摘の 1 行。見出し（要約）と場所を出し、本文は開いたときだけ出す（CodeRabbit の本文は長い）。
/// 1 行に複数のボタンを置くので、行のどこを押しても全部が反応しないよう、それぞれ borderless にする
private struct CodeRabbitFindingRow: View {
    let row: CodeRabbitFindingsModel.Row
    /// この画面で指示を投稿していれば、そのコメントの URL
    let instructedURL: URL?
    let instruct: () -> Void

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
            .buttonStyle(.borderless)
            HStack {
                Link("GitHub で開く", destination: row.thread.finding.url)
                    .font(.caption)
                    .buttonStyle(.borderless)
                Spacer()
                if let instructedURL {
                    Link(destination: instructedURL) {
                        Label("指示しました", systemImage: "checkmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .buttonStyle(.borderless)
                } else {
                    Button("ループに直させる", systemImage: "wrench.and.screwdriver", action: instruct)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("instruct-loop-\(row.thread.finding.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coderabbit-finding-\(row.thread.finding.id)")
    }
}

/// 「ループに直させる」の確認。指摘の見出しと場所を見せ、補足（任意）を書いて最終 PR に指示を投稿する
private struct FinalInstructionSheet: View {
    let row: CodeRabbitFindingsModel.Row
    let model: CodeRabbitFindingsModel
    let mergeQueue: MergeQueueModel
    @State private var note = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("直させる指摘") {
                    Text(row.thread.summary.isEmpty ? "（見出しがありません）" : row.thread.summary)
                        .font(.headline)
                    Text(row.location)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("補足（任意）", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isEditing)
                        .accessibilityIdentifier("instruct-loop-note")
                } footer: {
                    Text("最終 PR に「この指摘を直して」とコメントします。ループが止まっていれば、オーケストレーター（手動ループなら担当者）が再開して直させます")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .keyboardDoneButton($isEditing)
            .navigationTitle("ループに直させる")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button("投稿") { post() }
                            .accessibilityIdentifier("instruct-loop-post")
                    }
                }
            }
        }
    }

    private func post() {
        isPosting = true
        errorMessage = nil
        Task {
            let failure = await model.instruct(fixing: row, note: note, using: mergeQueue)
            isPosting = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}
