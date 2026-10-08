import AskHubKit
import SwiftUI

/// 新しいアプリのリポジトリを、テンプレートから作る依頼を出す画面（`repo-request` の Issue を作るだけ）。
/// 作成・名前の変更・担当 PC への clone と担当への追加は、依頼先の担当リポジトリの担当 PC のオーケストレーターが行う
struct NewAppView: View {
    let model: IdeaRequestModel

    @State private var template = NewRepository.Template.standard
    @State private var owner = ""
    @State private var name = ""
    @State private var appName = ""
    /// 空なら `jp.shilokuma.<アプリ名>`
    @State private var bundleIdentifier = ""
    /// 既定は public（private では GitHub Actions の実行時間が課金の対象になるため）
    @State private var isPrivate = false
    /// 作成を任せる担当リポジトリ（`owner/repo`）
    @State private var hub: String?
    @FocusState private var isEditing: Bool

    private var request: RepositoryRequest {
        .create(NewRepository(
            repository: "\(owner)/\(name.trimmingCharacters(in: .whitespaces))",
            template: template,
            appName: appName.trimmingCharacters(in: .whitespaces),
            bundleIdentifier: resolvedBundleIdentifier,
            isPrivate: isPrivate
        ))
    }

    private var resolvedBundleIdentifier: String {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? NewRepository.defaultBundleIdentifier(appName: appName.trimmingCharacters(in: .whitespaces)) : trimmed
    }

    private var canSend: Bool {
        !model.isSendingRepositoryRequest && hub != nil && request.isValid
    }

    var body: some View {
        Form {
            Section("テンプレート") {
                Picker("テンプレート", selection: $template) {
                    ForEach(NewRepository.Template.allCases) { template in
                        Text(template.title).tag(template)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("template-picker")
            }

            Section {
                Picker("Organization", selection: $owner) {
                    ForEach(model.organizationChoices, id: \.self) { organization in
                        Text(organization).tag(organization)
                    }
                }
                TextField("例: my-app-ios", text: $name)
                    .focused($isEditing)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("repository-name")
                Toggle("private で作る", isOn: $isPrivate)
                    .accessibilityIdentifier("private-toggle")
            } header: {
                Text("リポジトリ")
            } footer: {
                if !name.isEmpty, !RepositoryName.isValidFullName("\(owner)/\(name)") {
                    Text("英数字と - _ . だけにしてください")
                        .foregroundStyle(.red)
                } else {
                    Text(isPrivate
                        ? "private で作ります。GitHub Actions の実行時間が課金の対象になります"
                        : "public で作ります（GitHub Actions を無料で使えます）。誰でもコードを読めます")
                }
            }

            Section {
                TextField("例: MyApp", text: $appName)
                    .focused($isEditing)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("app-name")
                TextField(NewRepository.defaultBundleIdentifier(appName: appName.isEmpty ? "<アプリ名>" : appName), text: $bundleIdentifier)
                    .focused($isEditing)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("bundle-identifier")
            } header: {
                Text("アプリ名と Bundle ID")
            } footer: {
                if !appName.isEmpty, !NewRepository.isValidAppName(appName) {
                    Text("アプリ名は英字で始まる英数字にしてください（プロジェクト名になります）")
                        .foregroundStyle(.red)
                } else if !NewRepository.isValidBundleIdentifier(resolvedBundleIdentifier), !appName.isEmpty {
                    Text("Bundle ID の形式が正しくありません")
                        .foregroundStyle(.red)
                } else {
                    Text("Bundle ID を空にすると \(NewRepository.bundleIdentifierPrefix)<アプリ名> になります")
                }
            }

            Section {
                Picker("作成を任せる PC", selection: $hub) {
                    Text("選択してください").tag(String?.none)
                    ForEach(model.assignedRepositories(now: Date()), id: \.self) { repository in
                        Text(InboxSubject.shortRepository(repository)).tag(Optional(repository))
                    }
                }
                .accessibilityIdentifier("hub-picker")
            } header: {
                Text("担当 PC")
            } footer: {
                Text("選んだリポジトリの担当 PC がリポジトリを作り、clone して担当リポジトリに加えます。"
                    + "epic ごとにオーケストレーターで回すか手で回すかは、回答画面の「回し方」で選べます")
            }

            if let errorMessage = model.repositoryRequestError {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            let created = model.sentRepositoryRequests.filter {
                if case .create = $0.request { true } else { false }
            }
            if !created.isEmpty {
                Section {
                    ForEach(created) { sent in
                        SentRepositoryRequestRow(sent: sent)
                    }
                } header: {
                    Text("送った依頼")
                } footer: {
                    Text("作り終えると、依頼 Issue に結果がコメントされます。App Store Connect でのアプリの作成は、新しいリポジトリの Issue として実機確認タブに出ます")
                }
            }

            Section {
                Button {
                    isEditing = false
                    Task {
                        if await model.send(request, to: hub ?? "") != nil {
                            name = ""
                            appName = ""
                            bundleIdentifier = ""
                        }
                    }
                } label: {
                    if model.isSendingRepositoryRequest {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("作成を依頼する")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!canSend)
            }
        }
        .formStyle(.grouped)
        .keyboardDoneButton($isEditing)
        .navigationTitle("新しいアプリ")
        .onAppear {
            if owner.isEmpty {
                owner = model.organizationChoices.first ?? ""
            }
            if hub == nil {
                hub = model.assignedRepositories(now: Date()).first
            }
        }
    }
}

/// 送った作成・削除の依頼の 1 行
struct SentRepositoryRequestRow: View {
    let sent: SentRepositoryRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(sent.message, systemImage: "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true)
            Link(sent.linkTitle, destination: sent.issue.htmlURL)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        NewAppView(model: .sample())
    }
}
#endif
