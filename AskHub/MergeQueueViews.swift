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
        // デモモードの切り替えでモデルが差し替わったら、新しいモデルで取り直す
        .task(id: ObjectIdentifier(model)) { await model.refreshIfStale() }
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
                TryDemoButton()
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

/// 「マージ待ち」の詳細。まとめ・CI・マージ可否を出し、確認してから merge commit でマージする。
/// マージの前に epic ブランチを TestFlight に上げる（Upload ワークフローの起動と run の状態。Discussion #449）
struct MergeDetailView: View {
    let pullRequest: EpicPullRequest
    let model: MergeQueueModel
    /// 本文（まとめ）のブロック要素。変換は描画のたびに走らせず、画面を作るときに 1 回だけ行う
    private let renderedBody: RenderedBody
    @State private var isConfirming = false
    @State private var isMerging = false
    @State private var isConfirmingUpload = false
    @State private var isUploading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss)
    private var dismiss

    init(pullRequest: EpicPullRequest, model: MergeQueueModel) {
        self.pullRequest = pullRequest
        self.model = model
        renderedBody = RenderedBody(body: pullRequest.body)
    }

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
                // 情報として出すだけで、マージできるか（canMerge）には関係しない（Discussion #460）
                LabeledContent("CodeRabbit", value: codeRabbitText)
            }

            if model.showsUploadButton(latest) {
                UploadRunSection(
                    pullRequest: latest,
                    isUploading: isUploading,
                    canUpload: model.canUpload(latest),
                    blockingReason: model.uploadBlockingReason(latest)
                ) {
                    isConfirmingUpload = true
                }
            }

            Section("まとめ") {
                if renderedBody.blocks.isEmpty {
                    Text("（本文がありません）")
                        .foregroundStyle(.secondary)
                } else {
                    RenderedBodyView(content: renderedBody)
                }
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
        // App Store Connect の 1 日のアップロード上限を消費するので、押す前に確かめる
        .confirmationDialog(
            "\(pullRequest.headBranch) を TestFlight に上げますか？",
            isPresented: $isConfirmingUpload,
            titleVisibility: .visible
        ) {
            Button("TestFlight に上げる") { upload() }
        } message: {
            Text("Upload ワークフローを \(pullRequest.headBranch) で実行します。ビルド番号は App Store Connect の最新から自動で増えます")
        }
    }

    /// 一覧にある最新の値（取り直した後の run の状態を反映する）
    private var latest: EpicPullRequest {
        model.current(pullRequest)
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

    private var codeRabbitText: String {
        switch pullRequest.codeRabbit {
        case .inProgress:
            "処理中"

        case .completed:
            "完了"

        case .rateLimited:
            "レート制限"

        case .failed:
            "失敗"

        case .none:
            "なし"
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

    private func upload() {
        isUploading = true
        errorMessage = nil
        Task {
            defer { isUploading = false }
            do {
                try await model.upload(latest)
            } catch {
                errorMessage = MergeQueueModel.message(for: error)
            }
        }
    }
}

/// TestFlight へのアップロード（Upload ワークフローの直近の run の状態と「TestFlight に上げる」）
struct UploadRunSection: View {
    let pullRequest: EpicPullRequest
    let isUploading: Bool
    let canUpload: Bool
    let blockingReason: String?
    let upload: () -> Void

    var body: some View {
        Section {
            LabeledContent("Upload", value: statusText)
            if let run = pullRequest.uploadStatus.run {
                LabeledContent("ビルドしたコミット", value: builtCommitText(run))
                LabeledContent("開始", value: run.startedAt.formatted(date: .abbreviated, time: .shortened))
                Link("run を GitHub で見る", destination: run.url)
            }
            Button {
                upload()
            } label: {
                if isUploading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("TestFlight に上げる")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!canUpload || isUploading)
        } header: {
            Text("TestFlight")
        } footer: {
            Text(blockingReason ?? "Upload ワークフローを \(pullRequest.headBranch) で実行し、TestFlight に上げます。TestFlight 側の処理状況はここには出ません")
        }
    }

    /// 直近の run の状態。TestFlight 側の処理（テストできるようになったか）は追わない
    private var statusText: String {
        switch pullRequest.uploadStatus {
        case .notLoaded:
            return "未取得"

        case .unsupported:
            return "対応していません"

        case .noRuns:
            return "まだ上げていません"

        case .permissionDenied:
            return "トークンに Actions の権限がありません"

        case .unavailable:
            return "取得できませんでした"

        case .run(let run):
            return Self.runText(run)
        }
    }

    /// run の状態の表記。終わった run は結論で分ける（cancelled は失敗と区別する）
    static func runText(_ run: UploadWorkflowRun) -> String {
        guard run.status == .completed else {
            return "実行中"
        }
        switch run.conclusion {
        case .success:
            return "成功"

        case .failure:
            return "失敗"

        case .cancelled:
            return "キャンセル"

        case .other(let raw) where !raw.isEmpty:
            return "終了（\(raw)）"

        case .other, nil:
            return "終了（結論なし）"
        }
    }

    private func builtCommitText(_ run: UploadWorkflowRun) -> String {
        let short = String(run.headSHA.prefix(7))
        return run.builtHead(pullRequest.headSHA) ? "\(short)（PR の最新の head）" : "\(short)（PR の最新の head と違います）"
    }
}
