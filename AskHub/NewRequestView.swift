import AskHubKit
import SwiftUI

/// 新機能の依頼を出す画面（Discussion #1 の Q12）。`idea-request` の Issue を作るだけで、Claude は呼ばない
struct NewRequestView: View {
    let model: IdeaRequestModel
    let openSettings: () -> Void
    /// 送信後にキーボードを閉じ、結果が隠れないようにする
    @FocusState private var isEditing: Bool

    var body: some View {
        @Bindable var model = model
        Form {
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
            } header: {
                Text("要約")
            } footer: {
                Text("Issue のタイトルは「【依頼】要約」になります")
            }

            Section("依頼文") {
                TextField("やりたいこと・背景・決まっていることなど", text: $model.body, axis: .vertical)
                    .lineLimit(5...12)
                    .focused($isEditing)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let created = model.created {
                Section {
                    Label("依頼を送りました", systemImage: "checkmark.circle")
                    Link("#\(created.number) を GitHub で開く", destination: created.htmlURL)
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
        }
        .formStyle(.grouped)
        .navigationTitle("新しい依頼")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
        .task { await model.loadRepositories() }
        .refreshable { await model.loadRepositories() }
    }

    @ViewBuilder private var repositoryPicker: some View {
        @Bindable var model = model
        switch model.repositoriesState {
        case .needsToken:
            Button("トークンを設定する", action: openSettings)

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
                ForEach(model.repositorySections) { section in
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
#endif
