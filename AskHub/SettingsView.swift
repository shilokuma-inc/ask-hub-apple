import AskHubKit
import SwiftUI

/// GitHub のトークン、一覧を取得する organization、ループの既定値を設定する画面
struct SettingsView: View {
    @State private var model: TokenSettingsModel
    @State private var organizationModel: OrganizationSettingsModel
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

    init(model: TokenSettingsModel = TokenSettingsModel(), organizationModel: OrganizationSettingsModel = OrganizationSettingsModel()) {
        _model = State(initialValue: model)
        _organizationModel = State(initialValue: organizationModel)
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
                    NavigationLink {
                        OrganizationSettingsView(model: organizationModel)
                    } label: {
                        LabeledContent("organization", value: organizationModel.logins.joined(separator: ", "))
                    }
                } header: {
                    Text("取得する organization")
                } footer: {
                    Text("依頼・要対応・任意判断・ステータス・実機確認に、ここに並べた organization のリポジトリを出します。")
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

/// 一覧を取得する organization を追加・削除する画面
struct OrganizationSettingsView: View {
    @Bindable var model: OrganizationSettingsModel
    @FocusState private var isEditing: Bool

    var body: some View {
        Form {
            Section {
                ForEach(model.logins, id: \.self) { login in
                    HStack {
                        Text(login)
                        Spacer()
                        Button("削除", role: .destructive) { model.remove(login) }
                            .buttonStyle(.borderless)
                            .disabled(!model.canRemove)
                    }
                }
            } footer: {
                Text("""
                    並べた順に取得します。最後の 1 つは削除できません。\
                    Fine-grained PAT は 1 つの owner にしか使えないので、\
                    複数の organization に回答・依頼するなら、すべてに書き込めるトークンを保存してください。
                    """)
            }

            Section {
                TextField("shilokuma-inc", text: $model.input)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    // organization の名前は英数字とハイフンなので、英字のキーボードで小文字のまま入力できるようにする
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($isEditing)
                    .onSubmit { model.add() }
                Button("追加") { model.add() }
                    .disabled(!model.canAdd)
            } header: {
                Text("organization を追加")
            } footer: {
                Text("GitHub の organization の名前（URL の github.com/ の後ろ）を入力してください。")
            }
        }
        .formStyle(.grouped)
        .keyboardDoneButton($isEditing)
        .navigationTitle("取得する organization")
    }
}

#Preview("未設定") {
    SettingsView(model: TokenSettingsModel(store: InMemoryTokenStore()))
}

#Preview("保存済み") {
    SettingsView(model: TokenSettingsModel(store: InMemoryTokenStore(token: "github_pat_preview")))
}
