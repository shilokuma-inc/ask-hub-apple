import AskHubKit
import SwiftUI

/// GitHub のトークンなどを設定する画面
struct SettingsView: View {
    @State private var model: TokenSettingsModel
    @AppStorage(LoopStartPreference.defaultsKey)
    private var startsLoopAfterPosting = LoopStartPreference.defaultValue
    /// キーボードの「完了」でキーボードを閉じ、下のボタンが隠れないようにする
    @FocusState private var isEditingToken: Bool
    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.isDemoMode)
    private var isDemoMode
    @Environment(\.setDemoMode)
    private var setDemoMode

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

                Section {
                    Toggle("投稿したらループを始める", isOn: $startsLoopAfterPosting)
                } header: {
                    Text("ループ")
                } footer: {
                    Text("Discussion の最後の未回答の質問に答えるとき、回答画面の「投稿したら、回答を確定してループを始める」をこの値から始めます。回答画面で切り替えることもでき、ループを始める前には確認を出します。")
                }

                if let setDemoMode {
                    Section {
                        if isDemoMode {
                            Button("デモモードを終了") {
                                setDemoMode(false)
                                dismiss()
                            }
                        } else {
                            Button("サンプルデータで試す") {
                                setDemoMode(true)
                                dismiss()
                            }
                        }
                    } header: {
                        Text("デモモード")
                    } footer: {
                        Text("GitHub に接続せず、サンプルデータで画面と操作を試せます。回答・マージ・依頼は送ったことにするだけで、GitHub には反映されません。")
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
