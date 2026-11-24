import AskHubProtocol
import SwiftUI

/// 依頼の画面の「新しいアプリ」の欄。テンプレート・作る先（持ち主と名前）・アプリ名・Bundle ID・公開範囲を選ぶ。
/// 作る先の持ち主は、司令塔に管理用のトークンを入れた持ち主だけを出す（ほかの持ち主には作れない）
struct NewAppSections: View {
    /// アプリ名・Bundle ID を人が直したか（直していなければ、リポジトリの名前・アプリ名から決まる案に合わせ続ける）
    struct Edits: Hashable {
        var appName = false
        var bundleId = false
    }

    @Binding var request: NewAppRequest
    /// 欄が作り直されても残るよう、親が入れた値と一緒に持つ
    @Binding var edits: Edits
    /// 管理用のトークンを入れた持ち主
    let owners: [String]
    /// 親の入力欄のフォーカス。キーボードの「完了」で、この欄のキーボードも閉じる
    let isEditing: FocusState<Bool>.Binding

    var body: some View {
        Section {
            Picker("テンプレート", selection: $request.template) {
                ForEach(RepositoryTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: request.template) { selectPreferredOwner() }
        } header: {
            Text("テンプレート")
        } footer: {
            Text("\(request.template.repository.rawValue) から作ります")
        }
        Section {
            if owners.isEmpty {
                Label("管理用のトークンを入れた持ち主がありません。常時オンの Mac で askhub-commander admin-token <持ち主> を流してください",
                      systemImage: "key.slash")
                    .foregroundStyle(.secondary)
            } else {
                Picker("持ち主", selection: $request.owner) {
                    ForEach(owners, id: \.self) { owner in
                        Text(owner).tag(owner)
                    }
                }
            }
            textField("リポジトリの名前", prompt: "例: memo-widget-ios", text: $request.name, identifier: "new-app-name")
                .onChange(of: request.name) { suggestNames() }
        } header: {
            Text("作る先")
        } footer: {
            Text("作る先の持ち主の管理用のトークンは、Repository access を All repositories にしておきます（作る前のリポジトリは選べないため）")
        }
        Section {
            textField("アプリ名", prompt: "例: MemoWidget", text: appName, identifier: "new-app-app-name")
            textField("Bundle ID", prompt: "例: jp.shilokuma.MemoWidget", text: bundleId, identifier: "new-app-bundle-id")
            Picker("公開範囲", selection: $request.visibility) {
                Text("public").tag(RepositoryVisibility.public)
                Text("private").tag(RepositoryVisibility.private)
            }
        } header: {
            Text("アプリ")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: selectPreferredOwner)
    }

    private var footer: String {
        let names = "アプリ名は英字で始まる英数字です（Xcode のプロジェクト名・Swift のモジュール名になります）。"
        let after = "作ると、司令塔がアプリ名と Bundle ID を書き換えて develop に入れ、対象に加えて Discussions などの準備とビルドの設定まで済ませます。"
        let token = "作った後、毎日のトークン（司令塔と各 Mac）の Repository access にも足してください"
        let visibility = request.visibility == .private ? "private では、今のプランだと保護（ルールセット）を掛けられません。" : ""
        return names + after + visibility + token
    }

    /// 英数字の入力欄（リポジトリの名前・アプリ名・Bundle ID）。例の文だけでは入れた後にどの欄か分からないので、iOS でも名前を左に出す。
    /// 名前は LabeledContent が出すので、Mac で入力欄の左にもう一度並べない
    private func textField(_ title: String, prompt: String, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .focused(isEditing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                // 英数字しか使えないので、日本語のキーボードを出さない
                .keyboardType(.asciiCapable)
                #endif
                .accessibilityIdentifier(identifier)
        }
    }

    private var appName: Binding<String> {
        Binding {
            request.appName
        } set: { value in
            edits.appName = true
            request.appName = value
            if !edits.bundleId { request.bundleId = CreateRepositoryIntent.defaultBundleId(appName: value) }
        }
    }

    private var bundleId: Binding<String> {
        Binding {
            request.bundleId
        } set: { value in
            edits.bundleId = true
            request.bundleId = value
        }
    }

    /// 人が直していなければ、リポジトリの名前からアプリ名と Bundle ID の案を入れる
    private func suggestNames() {
        guard !edits.appName else { return }
        request.appName = NewAppRequest.suggestedAppName(from: request.name)
        if !edits.bundleId { request.bundleId = CreateRepositoryIntent.defaultBundleId(appName: request.appName) }
    }

    /// テンプレートのある持ち主を既定に選ぶ。選べる持ち主に無ければ先頭
    private func selectPreferredOwner() {
        let preferred = NewAppRequest.preferredOwner(for: request.template)
        if let match = owners.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
            request.owner = match
        } else if !owners.contains(request.owner) {
            request.owner = owners.first ?? ""
        }
    }
}
