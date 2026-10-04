import AskHubKit
import SwiftUI

/// 「マージ待ち」の一覧（Discussion #1 の Q13）
struct MergeQueueListView: View {
    let model: MergeQueueModel
    let openSettings: () -> Void

    var body: some View {
        List(model.pullRequests) { pullRequest in
            NavigationLink(value: pullRequest) {
                EpicPullRequestRow(pullRequest: pullRequest)
            }
        }
        .overlay {
            if model.pullRequests.isEmpty {
                emptyState
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("マージ待ち")
        .navigationDestination(for: EpicPullRequest.self) { pullRequest in
            MergeDetailView(pullRequest: pullRequest, model: model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
        // 起動時やフォアグラウンド復帰時に取得済みなら、タブを開いただけでは取り直さない
        .task { await model.refreshIfStale() }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()

        case .needsToken:
            ContentUnavailableView {
                Label("トークンが未設定です", systemImage: "key")
            } actions: {
                Button("設定を開く", action: openSettings)
            }

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView("マージ待ちの epic はありません", systemImage: "arrow.triangle.merge")
        }
    }
}

/// 「マージ待ち」の 1 行
struct EpicPullRequestRow: View {
    let pullRequest: EpicPullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(InboxSubject.shortRepository(pullRequest.repository))#\(pullRequest.number)")
                    .foregroundStyle(.secondary)
                Spacer()
                MergeStatusLabel(pullRequest: pullRequest)
            }
            .font(.caption)

            Text(pullRequest.title)
                .lineLimit(2)

            Text("\(pullRequest.baseBranch) ← \(pullRequest.headBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// マージできるか（CI とコンフリクト）の印
struct MergeStatusLabel: View {
    let pullRequest: EpicPullRequest

    var body: some View {
        if pullRequest.canMerge {
            Label("マージできます", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label(pullRequest.blockingReason ?? "", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }
}

/// 「マージ待ち」の詳細。まとめ・CI・マージ可否を出し、確認してから merge commit でマージする
struct MergeDetailView: View {
    let pullRequest: EpicPullRequest
    let model: MergeQueueModel
    @State private var isConfirming = false
    @State private var isMerging = false
    @State private var errorMessage: String?
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Pull Request", value: "\(InboxSubject.shortRepository(pullRequest.repository))#\(pullRequest.number)")
                Text(pullRequest.title)
                LabeledContent("マージ先", value: "\(pullRequest.baseBranch) ← \(pullRequest.headBranch)")
                Link("差分を GitHub で見る", destination: pullRequest.filesURL)
            }

            Section("状態") {
                LabeledContent("CI", value: checksText)
                LabeledContent("コンフリクト", value: mergeabilityText)
            }

            Section("まとめ") {
                Text(summary)
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    isConfirming = true
                } label: {
                    if isMerging {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("\(pullRequest.baseBranch) にマージ")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!pullRequest.canMerge || isMerging)
            } footer: {
                Text(pullRequest.blockingReason ?? "merge commit でマージし、\(pullRequest.headBranch) を削除します")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("#\(pullRequest.number)")
        // マージは取り消せないので、マージ先と PR のタイトルを見せて確かめる
        .confirmationDialog(
            "\(pullRequest.baseBranch) にマージしますか？",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("\(pullRequest.baseBranch) にマージする", role: .destructive) { merge() }
        } message: {
            Text("\(pullRequest.title)\n\(pullRequest.repository)#\(pullRequest.number)（merge commit。\(pullRequest.headBranch) は削除されます）")
        }
    }

    private var summary: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let body = pullRequest.body.isEmpty ? "（本文がありません）" : pullRequest.body
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }

    private var checksText: String {
        switch pullRequest.checks {
        case .success:
            "成功"

        case .pending:
            "実行中"

        case .failure:
            "失敗"

        case .none:
            "なし"
        }
    }

    private var mergeabilityText: String {
        switch pullRequest.mergeability {
        case .mergeable:
            "なし"

        case .conflicting:
            "あり"

        case .unknown:
            "確認中"
        }
    }

    private func merge() {
        isMerging = true
        errorMessage = nil
        Task {
            defer { isMerging = false }
            do {
                try await model.merge(pullRequest)
                dismiss()
            } catch {
                errorMessage = MergeQueueModel.message(for: error)
            }
        }
    }
}
