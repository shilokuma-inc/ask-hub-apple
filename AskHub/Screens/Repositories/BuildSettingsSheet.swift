import SwiftUI

/// リポジトリの画面の「ビルドの設定」。入れていなければ、開始の前に要ることを出す。
/// シートは List の外（リポジトリの画面）に付ける（List の中のセクションに付けると開かない）
struct BuildSettingsSection: View {
    let repository: TargetRepository
    @Binding var isEditing: Bool

    @Environment(ClientStore.self) private var store

    var body: some View {
        CardSection {
            if let build = repository.build {
                LabeledContent("スキーム", value: build.scheme)
                LabeledContent("行き先", value: build.destinations.joined(separator: "・"))
                LabeledContent("子 PR で待つ", value: build.childChecks.joined(separator: "・"))
                LabeledContent("最終 PR で待つ", value: build.finalChecks.joined(separator: "・"))
            } else {
                Label("まだありません。開始する前に入れてください", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button(repository.build == nil ? "設定する…" : "直す…", systemImage: "slider.horizontal.3") { isEditing = true }
                // 前の操作（加える・外す・設定）の同期を待つ間は押せなくする
                .disabled(store.isReflecting([.repository(repository.id)]))
        } header: {
            Text("ビルドの設定")
        } footer: {
            Text("ワーカーはこの設定でビルド・テストし、子 PR と最終 PR のチェックを待ちます")
        }
    }
}

/// ビルドの設定（`repo.json` の `build`）を入れる・直す。主な欄はフォームで、ほかの欄（テストの絞り込み・スクショなど）は JSON で直す
/// （ユーザーの決定。2026-11-12）。送る前に司令塔と同じ決まりで確かめ、送るたびに設定をまるごと置き換える
struct BuildSettingsSheet: View {
    let repository: TargetRepository

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BuildSettingsDraft
    @State private var editsJSON = false
    @State private var json = ""
    /// JSON からフォームに戻れなかったわけ
    @State private var jsonProblem: String?
    @State private var sending = SheetSendState()
    @FocusState private var isEditing: Bool

    init(repository: TargetRepository) {
        self.repository = repository
        _draft = State(initialValue: BuildSettingsDraft(json: repository.build?.json))
    }

    private var canSend: Bool {
        editsJSON ? !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !draft.project.isEmpty && !draft.scheme.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                Group {
                    Section {
                        Picker("直し方", selection: mode) {
                            Text("フォーム").tag(false)
                            Text("JSON").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } footer: {
                        Text(jsonProblem ?? "テストの絞り込み・スクショの撮り方などは JSON で直します。フォームに出さない欄は、そのまま残します")
                            .foregroundStyle(jsonProblem == nil ? Color.secondary : Color.red)
                    }
                    if editsJSON {
                        Section("repo.json の build") {
                            TextField("JSON", text: $json, axis: .vertical)
                                .labelsHidden()
                                .font(.system(.footnote, design: .monospaced))
                                .autocorrectionDisabled()
                                .lineLimit(12...40)
                                .focused($isEditing)
                        }
                    } else {
                        BuildSettingsForm(draft: $draft, isEditing: $isEditing)
                    }
                }
                .disabled(sending.isSending)
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("ビルドの設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("送る", isSending: sending.isSending) { submit() }
                        .disabled(!canSend)
                }
            }
            .keyboardDoneButton($isEditing)
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    /// フォームと JSON の切り替え。JSON として読めないときは、直した中身を失わないようフォームに戻さない
    private var mode: Binding<Bool> {
        Binding {
            editsJSON
        } set: { toJSON in
            if toJSON {
                json = draft.text
                jsonProblem = nil
                editsJSON = true
            } else if BuildSettingsDraft.isJSONObject(json) {
                draft = BuildSettingsDraft(json: json)
                jsonProblem = nil
                editsJSON = false
            } else {
                jsonProblem = "JSON として読めないので、フォームに戻せません。直してから切り替えてください"
            }
        }
    }

    private func submit() {
        guard canSend, !sending.isSending else {
            return
        }
        isEditing = false
        let intent = HumanIntent.configureRepository(repositoryID: repository.id, json: editsJSON ? json : draft.text)
        Task {
            guard case .sent = await sending.send(intent, in: store) else {
                return
            }
            dismiss()
        }
    }
}

/// ビルドの設定の主な欄
private struct BuildSettingsForm: View {
    @Binding var draft: BuildSettingsDraft
    var isEditing: FocusState<Bool>.Binding

    var body: some View {
        Section {
            labeled("プロジェクト", prompt: "App.xcodeproj", text: $draft.project)
            labeled("スキーム", prompt: "App", text: $draft.scheme)
            labeled("base のブランチ", prompt: "develop", text: $draft.baseBranch)
            Toggle("XcodeGen でプロジェクトを作る", isOn: $draft.usesXcodeGen)
        } header: {
            Text("プロジェクト")
        } footer: {
            Text("パスはリポジトリの直下から書きます")
        }
        Section {
            ForEach($draft.destinations) { $destination in
                destinationRow($destination)
            }
            .onDelete { draft.destinations.remove(atOffsets: $0) }
            Button("行き先を足す", systemImage: "plus") {
                draft.destinations.append(.init(platform: "iOS", deviceType: "iPhone 17 Pro"))
            }
        } header: {
            Text("行き先")
        } footer: {
            Text("並べた順に流します。OS を空にすると、使う Xcode に合う最新のものにします")
        }
        Section {
            field("子 PR で待つチェック（1 行に 1 つ）", text: $draft.childChecks, multiline: true)
        } header: {
            Text("子 PR で待つチェック")
        } footer: {
            Text("PR の画面のチェックの名前です（例: build / build）。1 つ以上要ります")
        }
        Section("最終 PR で待つチェック") {
            field("最終 PR で待つチェック（1 行に 1 つ）", text: $draft.finalChecks, multiline: true)
        }
        Section {
            field("例: coderabbitai[bot]", text: $draft.trustedReviewers, multiline: true)
        } header: {
            Text("指摘を Claude に渡すレビューの書き手")
        } footer: {
            Text("CodeRabbit を入れていない organization のリポジトリでは空にします")
        }
    }

    private func destinationRow(_ destination: Binding<BuildSettingsDraft.Destination>) -> some View {
        VStack(alignment: .leading) {
            Picker("プラットフォーム", selection: destination.platform) {
                ForEach(BuildSettingsDraft.platforms, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if destination.wrappedValue.platform != "macOS" {
                labeled("機種", prompt: "iPhone 17 Pro", text: destination.deviceType)
                labeled("OS の版", prompt: "空なら最新", text: destination.osVersion)
            }
        }
    }

    /// 値が入っていても何の欄か分かるよう、名前を左に出す
    private func labeled(_ label: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused(isEditing)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, multiline: Bool = false) -> some View {
        // Mac の Form では名前が入力欄の左に並んで欄が狭くなるので、名前は隠して入力欄の中に出す
        TextField(prompt, text: text, prompt: Text(prompt), axis: multiline ? .vertical : .horizontal)
            .labelsHidden()
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .lineLimit(multiline ? 1...6 : 1...1)
            .focused(isEditing)
    }
}
