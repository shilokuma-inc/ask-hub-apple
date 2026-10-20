import AskHubKit
import SwiftUI

/// 準備中のリリースの進み具合（Discussion #605）。「リリース準備」でリポジトリを選ぶと、タグの無い release ブランチがあれば出す。
/// GitHub の情報（release ブランチ・下書きのファイル・各ワークフローの run）だけで出す（App Store Connect は見ない）
struct ReleaseProgressSection: View {
    let repository: String
    let progress: ReleaseProgress
    let notes: ReleaseNotesModel

    var body: some View {
        Section {
            ForEach(progress.steps) { step in
                ReleaseStepRow(step: step)
            }
            NavigationLink {
                ReleaseNotesView(model: notes)
            } label: {
                Label(notesLinkTitle, systemImage: "text.badge.checkmark")
            }
            .accessibilityIdentifier("open-release-notes")
            if progress.finishWorkflow.isUsable, let url = finishWorkflowURL {
                // リリース後作業は配信を検知して自動で始まる（Q7）。アプリからは起動せず、手で起動するときは GitHub で行う
                Link("リリース後作業を GitHub で手動実行する", destination: url)
                    .accessibilityIdentifier("open-release-finish-workflow")
            }
        } header: {
            Text("準備中のリリース \(progress.version.description)")
        } footer: {
            if notes.readFailure != nil {
                Text("読み直せなかったので、前に読んだ状態を出しています。App Store Connect の処理・審査の状況はアプリでは見られません")
            } else {
                Text("App Store Connect の処理・審査の状況はアプリでは見られません。リリース後作業は配信を検知すると自動で始まります")
            }
        }
    }

    private var notesLinkTitle: String {
        switch progress.releaseNotes?.status {
        case .draft: "最新情報の下書きを確かめて確定する"
        case .confirmed: "確定した最新情報を見る・直す"
        default: "最新情報を見る"
        }
    }

    private var finishWorkflowURL: URL? {
        URL(string: "https://github.com/\(repository)/actions/workflows/\(ReleaseWorkflow.finish.file)")
    }
}

/// 進み具合の 1 段
struct ReleaseStepRow: View {
    let step: ReleaseStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(statusText)
                    .foregroundStyle(statusColor)
            } label: {
                Label(step.title, systemImage: systemImage)
                    .foregroundStyle(statusColor)
            }
            .accessibilityIdentifier("release-step-\(step.id.rawValue)")
            Text(step.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = step.url {
                Link("run を GitHub で見る", destination: url)
                    .font(.footnote)
            }
        }
    }

    private var statusText: String {
        switch step.status {
        case .done: "済み"
        case .running: "実行中"
        case .waiting: "待ち"
        case .failed: "失敗"
        case .notStarted: "まだ"
        case .unavailable: "不明"
        }
    }

    private var systemImage: String {
        switch step.status {
        case .done: "checkmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hourglass"
        case .failed: "xmark.octagon.fill"
        case .notStarted: "circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .done: .green
        case .running: .blue
        case .waiting: .orange
        case .failed: .red
        case .notStarted, .unavailable: .secondary
        }
    }
}

/// 最新情報の下書きを言語ごとに確かめて直し、「確定して反映」で `release-notes.yml` を起動する画面
struct ReleaseNotesView: View {
    let model: ReleaseNotesModel

    @State private var isConfirming = false
    @FocusState private var isEditing: Bool

    var body: some View {
        @Bindable var model = model
        Form {
            if let readFailure = model.readFailure {
                Section {
                    Label(readFailure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } footer: {
                    Text("前に読んだ状態と入力中の本文を出しています。更新で読み直してください")
                }
            }

            if let notes = model.notes {
                Section {
                    LabeledContent("状態", value: statusText(notes))
                    if let run = model.progress?.notesWorkflow.run {
                        LabeledContent("確定の run", value: UploadRunSection.runText(run))
                        Link("run を GitHub で見る", destination: run.url)
                    }
                } header: {
                    Text("\(notes.version.branchName) の最新情報")
                } footer: {
                    if model.isDispatchPending() {
                        Text("起動した直後は run の一覧にまだ出ません。少し待つと自動で取り直します")
                    }
                }
            }

            ForEach(model.languages, id: \.self) { language in
                Section {
                    TextField("最新情報", text: textBinding(language), axis: .vertical)
                        .lineLimit(4...16)
                        .focused($isEditing)
                        // 欄が言語の数だけ並ぶので、読み上げでどの言語か分かるようにする
                        .accessibilityLabel("\(languageTitle(language))の最新情報")
                        .accessibilityIdentifier("whats-new-\(language)")
                } header: {
                    Text(languageTitle(language))
                } footer: {
                    if let problem = model.problem(for: language) {
                        Text(problem)
                            .foregroundStyle(.red)
                    } else {
                        Text("\(ReleaseNotesModel.length(of: model.texts[language] ?? "")) / \(ReleaseNotesModel.maxLength) 字")
                    }
                }
            }

            if let draft = model.draft {
                ReleaseDraftSourceSection(draft: draft)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    isEditing = false
                    isConfirming = true
                } label: {
                    if model.isConfirming {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("最新情報の確定を起動しています")
                    } else {
                        Text("確定して反映")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!model.canConfirm())
                .accessibilityIdentifier("confirm-release-notes")
            } footer: {
                if let reason = model.blockingReason() {
                    Text(reason)
                        .foregroundStyle(.red)
                } else {
                    Text("release ブランチの AppStore/metadata の whatsNew に書き、下書きを消して App Store Connect に反映します（\(ReleaseWorkflow.notes.file)）")
                }
            }
        }
        .formStyle(.grouped)
        .keyboardDoneButton($isEditing)
        .navigationTitle("最新情報")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await model.onNeedsRefresh?() }
                }
                .disabled(model.isReading)
            }
        }
        .refreshable { await model.onNeedsRefresh?() }
        .confirmationDialog(confirmationTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button("確定して反映") {
                Task { await model.confirm() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func textBinding(_ language: String) -> Binding<String> {
        Binding {
            model.texts[language] ?? ""
        } set: { text in
            model.texts[language] = text
        }
    }

    private func languageTitle(_ language: String) -> String {
        // アプリの画面は日本語だけなので、端末の言語によらず日本語で出す
        guard let name = Locale(identifier: "ja").localizedString(forIdentifier: language) else {
            return language
        }
        return "\(name)（\(language)）"
    }

    private func statusText(_ notes: ReleaseNotes) -> String {
        switch notes.status {
        case .draft: "下書き（未確定）"
        case .unsupportedDraft: "読めない下書き"
        case .confirmed: "確定済み"
        case .missing: "下書きなし"
        }
    }

    private var confirmationTitle: String {
        "\(model.version?.description ?? "") の最新情報を確定しますか？"
    }

    private var confirmationMessage: String {
        guard let version = model.version else {
            return ""
        }
        return """
            \(version.branchName) に \(model.languages.joined(separator: "・")) の最新情報を書き、\
            App Store Connect の iOS / macOS のバージョン \(version) に反映します。あとから直して確定し直せます
            """
    }
}

/// 下書きの元にした PR と、作ったときの説明
struct ReleaseDraftSourceSection: View {
    let draft: WhatsNewDraft

    var body: some View {
        Section {
            // 同じ説明が 2 回入っていても壊れないよう、並びの位置を id にする
            ForEach(Array(draft.messages.enumerated()), id: \.offset) { _, message in
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.pullRequests, id: \.number) { pullRequest in
                row(pullRequest)
            }
            if draft.omitted > 0 {
                Text("ほか \(draft.omitted) 件は 4000 字に収まらないため「ほか」にまとめました")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(header)
        } footer: {
            Text("「（載せない）」の付いた PR は本文に載せていません（CI・ドキュメントだけの PR など）")
        }
    }

    private var header: String {
        if let base = draft.base {
            return "\(base.name) から入った PR"
        }
        return "下書きの元にした PR（初めてのリリース）"
    }

    @ViewBuilder
    private func row(_ pullRequest: WhatsNewDraft.PullRequest) -> some View {
        // 色だけで区別しない（色の見分けにくい人・読み上げでも分かるよう、載せない PR には文字を付ける）
        let suffix = pullRequest.included ? "" : "（載せない）"
        let text = Text("#\(pullRequest.number) \(pullRequest.type.map { "【\($0)】" } ?? "")\(pullRequest.title)\(suffix)")
            .foregroundStyle(pullRequest.included ? .primary : .secondary)
        if let url = pullRequest.url {
            Link(destination: url) {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            text
        }
    }
}

#if DEBUG
#Preview("最新情報の下書き") {
    let model = ReleaseRequestModel.sample()
    NavigationStack {
        ReleaseNotesView(model: model.notes)
    }
    .task { await model.select(SampleReleaseReader.draftRepository) }
}
#endif
