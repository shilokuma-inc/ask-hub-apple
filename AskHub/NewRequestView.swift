import AskHubKit
import SwiftUI

/// 新機能の依頼を出す画面（Discussion #1 の Q12）。`idea-request` の Issue を作るだけで、Claude は呼ばない
struct NewRequestView: View {
    /// 依頼の種類。フォームの最上部のセグメントで切り替える（Discussion #306）
    enum Kind: CaseIterable, Identifiable {
        /// 既存のリポジトリへの機能追加・修正の依頼（`idea-request`）
        case change
        /// テンプレートから新しいアプリのリポジトリを作る依頼（`repo-request`）
        case newApp
        /// GitHub にある既存のリポジトリを担当 PC に入れる依頼（`repo-request` の `add`。Discussion #722）
        case addRepository
        /// リリース準備のワークフロー（`release-prepare.yml`）の起動（Discussion #605）。Issue は作らない
        case release

        var id: Self { self }

        var title: String {
            switch self {
            // セグメントが 4 つになり iPhone の幅では「機能追加・修正」が切れるので、短くする（Discussion #722）
            case .change: "追加・修正"
            case .newApp: "新しいアプリ"
            case .addRepository: "担当に入れる"
            case .release: "リリース準備"
            }
        }

        /// ナビゲーションバーのタイトル
        var navigationTitle: String {
            switch self {
            case .change: "新しい依頼"
            case .newApp: "新しいアプリ"
            case .addRepository: "担当に入れる"
            case .release: "リリース準備"
            }
        }
    }

    let model: IdeaRequestModel
    let openSettings: () -> Void
    /// タブを切り替えても選んだ側を保つ。アプリを起動し直すと「機能追加・修正」に戻る
    @State private var kind: Kind
    /// 送信後とキーボードの「完了」でキーボードを閉じ、結果やボタンが隠れないようにする
    @FocusState private var isEditing: Bool

    init(model: IdeaRequestModel, openSettings: @escaping () -> Void, kind: Kind = .change) {
        self.model = model
        self.openSettings = openSettings
        _kind = State(initialValue: kind)
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("依頼の種類", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("request-kind-picker")
            }

            switch kind {
            case .change:
                changeSections
            case .newApp:
                NewAppFormSections(model: model, isEditing: $isEditing)
            case .addRepository:
                AddRepositoryFormSections(model: model)
            case .release:
                ReleaseRequestFormSections(requestModel: model, model: model.release, openSettings: openSettings, isEditing: $isEditing)
            }
        }
        .formStyle(.grouped)
        // macOS では、フォームのどこに落としても添付になる（Discussion #784）。添付欄があるのは「追加・修正」だけ
        .attachmentDropTarget(
            attachments: $model.attachments,
            notices: $model.attachmentNotices,
            isEnabled: { kind == .change && !model.isSending }
        )
        .keyboardDoneButton($isEditing)
        .navigationTitle(kind.navigationTitle)
        .toolbar {
            // macOS では引っぱって更新（refreshable）が効かないので、ほかの画面と同じくボタンでも読み直せるようにする
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(model.repositoriesState == .loading || (kind == .release && model.release.isLoading))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
        // デモモードの切り替えでモデルが差し替わったら、新しいモデルで読み直す
        .task(id: ObjectIdentifier(model)) { await model.loadRepositories() }
        .refreshable { await refresh() }
    }

    /// 依頼先の一覧と、「リリース準備」ならリリースの状態を読み直す
    private func refresh() async {
        await model.loadRepositories()
        if kind == .release {
            await model.release.refresh()
        }
    }

    /// 既存のリポジトリへの依頼（機能追加・修正）の入力欄
    @ViewBuilder private var changeSections: some View {
        @Bindable var model = model
        Group {
            Section {
                repositoryPicker
            } header: {
                Text("リポジトリ")
            } footer: {
                if case let .failed(message) = model.repositoriesState {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("例: 通知の頻度を調整したい", text: $model.summary)
                    .focused($isEditing)
                    .attachmentDropExcluded()
            } header: {
                Text("要約")
            } footer: {
                Text("Issue のタイトルは「【依頼】要約」になります")
            }

            Section("依頼文") {
                TextField("やりたいこと・背景・決まっていることなど", text: $model.body, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($isEditing)
                    .attachmentDropExcluded()
            }

            // 送信中は一覧を変えさせない（送った後に一覧を空にするので、送信中に足したものが消えないように）
            AttachmentPickerSection(attachments: $model.attachments, notices: $model.attachmentNotices, isDisabled: model.isSending)

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if !model.sent.isEmpty {
                Section {
                    ForEach(model.sent) { sent in
                        VStack(alignment: .leading, spacing: 6) {
                            // 要約が長くても切り詰めずに折り返す
                            Label(sent.message, systemImage: "checkmark.circle")
                                .fixedSize(horizontal: false, vertical: true)
                            Link(sent.linkTitle, destination: sent.issue.htmlURL)
                        }
                    }
                } header: {
                    Text("送った依頼")
                } footer: {
                    Text("担当 PC のオーケストレーターが、質問付きの Discussion を作ります")
                }
            }

            Section {
                Button {
                    isEditing = false
                    Task { await model.send() }
                } label: {
                    if model.isSending {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("依頼を送る")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!model.canSend)
            }

            Section {
                SiriShortcutsHelpLink(title: "Siri・ショートカットからも依頼できます")
                    .accessibilityIdentifier("siri-help-request-link")
            }
        }
    }

    @ViewBuilder private var repositoryPicker: some View {
        @Bindable var model = model
        switch model.repositoriesState {
        case .needsToken:
            Button("トークンを設定する", action: openSettings)
            TryDemoButton()

        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity)

        case .loading where model.repositories.isEmpty:
            // 取り直し中は、前回の一覧を出したままにする
            ProgressView()
                .frame(maxWidth: .infinity)

        default:
            Picker("依頼先", selection: $model.repository) {
                Text("選択してください").tag(String?.none)
                ForEach(model.repositorySections(now: Date())) { section in
                    Section(section.title) {
                        ForEach(section.repositories, id: \.self) { repository in
                            Text(InboxSubject.shortRepository(repository)).tag(Optional(repository))
                        }
                    }
                }
            }
            .accessibilityIdentifier("repository-picker")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        NewRequestView(model: .sample(), openSettings: {})
    }
}

#Preview("新しいアプリ") {
    NavigationStack {
        NewRequestView(model: .sample(), openSettings: {}, kind: .newApp)
    }
}

#Preview("担当に入れる") {
    NavigationStack {
        NewRequestView(model: .sample(), openSettings: {}, kind: .addRepository)
    }
}

#Preview("送った依頼が複数") {
    NavigationStack {
        NewRequestView(model: .sample(sent: SentRequest.samples), openSettings: {})
    }
}
#endif
