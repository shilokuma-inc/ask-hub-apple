import SwiftUI

/// 設定の、データの選択・GitHub のトークン・この端末の鍵・送った意図の節
struct ConnectionSettingsSections: View {
    @AppStorage(DataSource.preferenceKey) private var dataSource: DataSource = .stateRepository
    @AppStorage(DemoScenario.preferenceKey) private var scenario: DemoScenario = .standard
    @AppStorage(StateConnection.repositoryPreferenceKey) private var repository = StateConnection.defaultRepository
    @Environment(ClientStore.self) private var store
    @State private var model = ConnectionSettingsModel()
    /// 入れている途中の名前では読みに行かないよう、確定してから設定に書く
    @State private var repositoryInput = ""

    var body: some View {
        dataSection
        if DataSource.current() == .stateRepository {
            tokenSection
            keySection
            sentSection
        }
    }

    private var dataSection: some View {
        Section {
            Picker("見るデータ", selection: $dataSource) {
                ForEach(DataSource.allCases, id: \.self) { source in
                    Text(source.label).tag(source)
                }
            }
            if dataSource == .demo {
                Picker("デモの場面", selection: $scenario) {
                    ForEach(DemoScenario.allCases, id: \.self) { scenario in
                        Text(scenario.label).tag(scenario)
                    }
                }
            } else {
                LabeledContent("状態リポジトリ") {
                    TextField("owner/name", text: $repositoryInput)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onAppear { repositoryInput = repository }
                        .onSubmit { repository = repositoryInput.trimmingCharacters(in: .whitespaces) }
                }
            }
        } header: {
            Text("データ")
        } footer: {
            Text(dataSource == .demo
                ? "架空のアプリと Mac のデータで動きます。GitHub には接続しません"
                : "状態リポジトリだけを読み、人の意図はこの端末の鍵で署名して置きます。各リポジトリの Discussion・PR には書きません")
        }
    }

    private var tokenSection: some View {
        Section {
            LabeledContent("状態", value: model.hasToken ? "保存済み" : "未設定")
            SecureField(model.hasToken ? "入れ直すトークン" : "トークン", text: $model.tokenInput)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("保存する") {
                Task {
                    await model.saveToken()
                    await store.refresh()
                }
            }
            .disabled(!model.canSaveToken)
            if model.hasToken {
                Button("消す", role: .destructive) { model.deleteToken() }
            }
        } header: {
            Text("GitHub のトークン")
        } footer: {
            Text("状態リポジトリの Contents の読み書きだけを許した Fine-grained token を入れます。この端末の Keychain にだけ置き、画面やログには出しません")
        }
    }

    @ViewBuilder private var keySection: some View {
        Section {
            if let key = model.key {
                LabeledContent("保存場所", value: key.isSecureEnclave ? "Secure Enclave" : "ソフトウェア（Simulator など）")
                LabeledContent("登録", value: registrationLabel)
                LabeledContent("鍵の id") {
                    Text(key.keyID).appFont(.caption).monospaced().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let command = model.registerCommand {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(command).appFont(.caption).monospaced().textSelection(.enabled)
                        CopyButton(value: command)
                    }
                }
                Button("登録を確かめ直す") { Task { await model.checkRegistration() } }
                    .disabled(!model.hasToken || model.isCheckingRegistration)
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red)
            }
        } header: {
            Text("この端末の鍵")
        } footer: {
            Text("上のコマンドを、非常口の鍵を入れた Mac のターミナルで流して、この端末の鍵を登録します。登録されるまで、送った意図は司令塔に断られます")
        }
        .task { await model.load() }
    }

    private var registrationLabel: String {
        switch model.registration {
        case nil:
            model.isCheckingRegistration ? "確かめています…" : "トークンを入れると確かめます"

        case .registered(let label)?:
            "登録済み（\(label)）"

        case .notRegistered(let account)?:
            account == nil ? "最初の鍵がまだありません" : "まだ登録されていません"

        case .unreadable(let message)?:
            message
        }
    }

    @ViewBuilder private var sentSection: some View {
        let sent = store.snapshot?.sentIntents ?? []
        if !sent.isEmpty {
            Section("送った意図") {
                ForEach(sent) { intent in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(intent.title)
                        Text(stateLabel(intent.state)).appFont(.caption).foregroundStyle(isRejected(intent.state) ? .red : .secondary)
                    }
                }
            }
        }
    }

    private func stateLabel(_ state: SentIntentStatus.State) -> String {
        switch state {
        case .waiting:
            "司令塔の処理を待っています"

        case .accepted(let date):
            "受け付けました · \(date.formatted(date: .abbreviated, time: .shortened))"

        case let .rejected(_, reason):
            "受け付けませんでした: \(reason)"
        }
    }

    private func isRejected(_ state: SentIntentStatus.State) -> Bool {
        if case .rejected = state {
            return true
        }
        return false
    }
}
