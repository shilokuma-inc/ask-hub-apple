import AskHubKit
import SwiftUI

/// GitHub のトークンを設定する画面
struct SettingsView: View {
    @State private var model: TokenSettingsModel
    /// キーボードの「完了」でキーボードを閉じ、下のボタンが隠れないようにする
    @FocusState private var isEditingToken: Bool
    @Environment(\.dismiss)
    private var dismiss

    init(model: TokenSettingsModel = TokenSettingsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("github_pat_…", text: $model.input)
                        .autocorrectionDisabled()
                        .focused($isEditingToken)
                        .onSubmit { model.save() }
                    Button("保存") { model.save() }
                        .disabled(!model.canSave)
                } header: {
                    Text("GitHub の Personal Access Token")
                } footer: {
                    Text("Fine-grained PAT を入力してください。トークンはこの端末の Keychain にだけ保存します。")
                }

                Section("状態") {
                    LabeledContent("トークン", value: model.hasSavedToken ? "保存済み" : "未設定")
                    if model.hasSavedToken {
                        Button("トークンを削除", role: .destructive) { model.delete() }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .keyboardDoneButton($isEditingToken)
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .task { model.load() }
        }
        #if os(macOS)
        // macOS のシートは内容の大きさに縮むため、フォームが読める幅を確保する
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }
}

#Preview("未設定") {
    SettingsView(model: TokenSettingsModel(store: InMemoryTokenStore()))
}

#Preview("保存済み") {
    SettingsView(model: TokenSettingsModel(store: InMemoryTokenStore(token: "github_pat_preview")))
}
