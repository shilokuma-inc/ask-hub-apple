import AskHubClient
import AskHubProtocol
import SwiftUI
import UniformTypeIdentifiers

/// 人がする作業（AskHub だけではできない作業）。手順・開くページ・渡すものを出し、終わったら知らせる
struct HumanTaskView: View {
    let epicID: Epic.ID
    let taskID: HumanTask.ID

    @Environment(ClientStore.self) private var store
    @State private var isImporting = false
    /// 選んだ渡すファイル（送るまで覚える）
    @State private var pickedFile: HandoverFile?
    /// 選んだファイルを渡せない理由
    @State private var pickNotice: String?
    /// Secrets に入れる値と、入れ始めたときのゴールの版。送ったらすぐ消す（暗号化した後の暗号文だけを送る。平文は端末の外に出さない）
    @State private var secretEntry = SecretEntry()
    /// 値を暗号化できなかった理由
    @State private var secretNotice: String?

    var body: some View {
        if let epic = store.epic(epicID), let task = epic.humanTask(taskID) {
            content(epic, task)
        } else {
            ContentUnavailableView("この作業は見つかりません", systemImage: "wrench")
        }
    }

    private func content(_ epic: Epic, _ task: HumanTask) -> some View {
        taskList(epic, task)
            // 入れている間にゴールが直されたら、Secrets の名前が変わったかもしれないので値を消す
            .onChange(of: epic.goal?.version) { _, version in
                if secretEntry.goalChanged(to: version) {
                    secretNotice = "ゴールが直されたので、入れた値を消しました。作業を見直してから入れ直してください"
                }
            }
    }

    private func taskList(_ epic: Epic, _ task: HumanTask) -> some View {
        List {
            CardSection {
                AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: epic.title, iconSize: 40)
                Text(task.title).rowFont(.title)
                Text(task.why).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    stateLabel(task.state, epic: epic, task: task)
                    ReflectionBadge([target(epic, task)], syncOnly: true)
                }
                // 終えたこと（渡すファイル）を送った後に、司令塔がしばらく受け取っていない・断ったときの理由
                ReflectionStatusView(target(epic, task))
            }
            CardSection("手順") {
                ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(index + 1). \(step.text)")
                        if let value = step.copyableValue {
                            HStack {
                                Text(value)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                CopyButton(value: value)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
                        }
                    }
                }
            }
            if !task.links.isEmpty {
                CardSection("開くページ") {
                    ForEach(task.links, id: \.url) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: "safari")
                        }
                    }
                }
            }
            // 終わったことを知らせる操作は、送れるときだけ出す（状態リポジトリでは段階 3 で足す）
            if task.needsHuman, store.supports(.completeHumanTask(epicID: epic.id, taskID: task.id)) {
                deliverableSection(epic, task)
                    .disabled(store.isReflecting([target(epic, task)]))
            }
        }
        .pastelBackground()
        .compactList()
        .detailTitle("人がする作業")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            pick(result)
        }
    }

    private func target(_ epic: Epic, _ task: HumanTask) -> IntentTarget {
        .humanTask(epicID: epic.id, taskID: task.id)
    }

    @ViewBuilder private func deliverableSection(_ epic: Epic, _ task: HumanTask) -> some View {
        switch task.deliverable {
        case .none:
            CardSection {
                completeButton(epic, task)
            } footer: {
                Text("押すと、司令塔が受け取って、この作業を前提にしているタスクのロックを外します")
            }

        case .file:
            fileSection(epic, task)

        case let .secret(name, repository):
            secretSection(epic, task, name: name, repository: repository)
        }
    }

    private func completeButton(_ epic: Epic, _ task: HumanTask) -> some View {
        Button("終わった", systemImage: "checkmark.circle") {
            Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id)) }
        }
        .accessibilityIdentifier("human-task-done")
    }

    /// ファイルを選び、大きさとハッシュを計ってから渡す。選んだファイルを確かめてから送れるよう、選ぶと送るを分ける
    private func fileSection(_ epic: Epic, _ task: HumanTask) -> some View {
        CardSection {
            if let file = pickedFile {
                LabeledContent {
                    Text(ByteFormat.string(Int64(file.size)))
                } label: {
                    Label(file.name, systemImage: "doc")
                }
                Button("このファイルを渡す", systemImage: "paperplane") {
                    pickedFile = nil
                    Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id, file: file)) }
                }
                .accessibilityIdentifier("human-task-hand-over")
            }
            Button(pickedFile == nil ? "ファイルを選ぶ…" : "選び直す…", systemImage: "doc.badge.plus") {
                isImporting = true
            }
            .accessibilityIdentifier("human-task-pick-file")
        } header: {
            Text("渡すもの")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let pickNotice {
                    Text(pickNotice)
                        .foregroundStyle(Theme.danger)
                }
                Text("秘密鍵・パスワード・トークン・API キーを含むファイルは渡さないでください。渡したファイルは状態リポジトリに残り、実装する Claude も読みます")
            }
        }
    }

    /// GitHub の Secrets に入れる作業。値を貼ると、この端末でリポジトリの公開鍵で暗号化し、暗号文だけを送る（司令塔が Secrets に入れる）。
    /// 公開鍵がまだ無ければ、司令塔に読ませる。GitHub の設定画面で自分で入れてから「終わった」を押すこともできる
    @ViewBuilder private func secretSection(_ epic: Epic, _ task: HumanTask, name: String, repository: String) -> some View {
        secretValueSection(epic, task, name: name, key: store.repository(epic.repositoryID)?.secretsKey)
        manualSecretSection(epic, task, name: name, repository: repository)
    }

    /// 値を貼って、暗号化して渡す。公開鍵がまだ無ければ、司令塔に読ませる
    private func secretValueSection(_ epic: Epic, _ task: HumanTask, name: String, key: SecretsPublicKey?) -> some View {
        CardSection {
            LabeledContent("Secrets の名前") {
                HStack {
                    Text(name)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    CopyButton(value: name)
                }
            }
            if let key {
                SecureField("値", text: secretValue(epic), prompt: Text("値を貼る"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("human-task-secret-value")
                Button("暗号化して渡す", systemImage: "lock.fill") {
                    handOver(epic, task, key: key)
                }
                .disabled(secretEntry.value.isEmpty)
                .accessibilityIdentifier("human-task-secret-send")
            } else {
                Button("GitHub の公開鍵を読む", systemImage: "key") {
                    Task { await store.send(.readSecretsKey(repositoryID: epic.repositoryID)) }
                }
                .disabled(store.isReflecting([.repository(epic.repositoryID)]))
                .accessibilityIdentifier("human-task-secret-read-key")
            }
        } header: {
            Text("渡すもの")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let secretNotice {
                    Text(secretNotice)
                        .foregroundStyle(Theme.danger)
                }
                Text(key == nil
                    ? "値を暗号化するための GitHub の公開鍵を、司令塔が読みます（管理用のトークンを使います）。読めたら、ここに値を入れられます"
                    : "値はこの端末で GitHub の公開鍵で暗号化し、暗号文だけを送ります。AskHub・司令塔・状態リポジトリに値は残りません")
            }
        }
    }

    /// 自分で GitHub の設定画面に入れてから「終わった」を押す
    private func manualSecretSection(_ epic: Epic, _ task: HumanTask, name: String, repository: String) -> some View {
        CardSection {
            if let url = Self.secretsSettingsURL(repository) {
                Link(destination: url) {
                    Label("GitHub の Secrets の設定を開く", systemImage: "safari")
                }
            }
            completeButton(epic, task)
        } header: {
            Text("GitHub で入れる")
        } footer: {
            let place = "GitHub の \(repository.isEmpty ? "リポジトリ" : repository) の Settings → Secrets and variables → Actions"
            Text("\(place) で、「\(name)」に値を入れてから押してください")
        }
    }

    /// 入れる値。入れ始めたときのゴールの版を覚える
    private func secretValue(_ epic: Epic) -> Binding<String> {
        Binding {
            secretEntry.value
        } set: { text in
            secretEntry.edit(text, goalVersion: epic.goal?.version)
        }
    }

    /// 値を暗号化して送る。暗号化できたら、入れた値はすぐ消す
    private func handOver(_ epic: Epic, _ task: HumanTask, key: SecretsPublicKey) {
        guard Data(secretEntry.value.utf8).count <= EncryptedSecret.maximumValueLength else {
            secretNotice = "値が大きすぎます。GitHub の Secrets には \(EncryptedSecret.maximumValueLength / 1024) KB までの値を入れられます"
            return
        }
        // 入れ始めたときのゴールの版で送る（送るまでに版が変わっていれば、司令塔が断る）
        guard let goalVersion = secretEntry.goalVersion else {
            secretNotice = "ゴールを読めていません。取り直してから入れ直してください"
            return
        }
        guard let secret = Self.encrypt(secretEntry.value, with: key) else {
            secretNotice = "値を暗号化できませんでした。公開鍵を読み直してください"
            return
        }
        secretEntry.clear()
        secretNotice = nil
        Task { await store.send(.handOverSecret(epicID: epic.id, taskID: task.id, goalVersion: goalVersion, secret: secret)) }
    }

    /// 値を公開鍵で暗号化した暗号文（sealed box）。鍵の形が違う・値が大きすぎるときは nil
    static func encrypt(_ value: String, with key: SecretsPublicKey) -> EncryptedSecret? {
        let data = Data(value.utf8)
        guard let publicKey = key.keyData, (1...EncryptedSecret.maximumValueLength).contains(data.count),
              let sealed = try? SealedBox.seal(data, to: publicKey) else {
            return nil
        }
        return EncryptedSecret(keyId: key.keyId, encryptedValue: sealed.base64EncodedString())
    }

    /// リポジトリ（owner/name）の Actions の Secrets の設定画面。分からなければ nil
    static func secretsSettingsURL(_ repository: String) -> URL? {
        let parts = repository.split(separator: "/")
        guard parts.count == 2 else {
            return nil
        }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/settings/secrets/actions")
    }

    private func pick(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            switch HandoverFile.read(url) {
            case .success(let file):
                pickedFile = file
                pickNotice = nil

            case .failure(let failure):
                pickNotice = failure.message
            }

        case .failure:
            pickNotice = "ファイルを読み込めませんでした"
        }
    }

    @ViewBuilder private func stateLabel(_ state: HumanTask.State, epic: Epic, task: HumanTask) -> some View {
        switch state {
        case .todo:
            let blocked = epic.tasks.filter { task.blocksTaskIDs.contains($0.id) }.map { "タスク \($0.number)" }
            if !blocked.isEmpty {
                Label("\(blocked.joined(separator: "・")) の前提です。ほかのタスクは進めています", systemImage: "lock")
                    .appFont(.footnote)
                    .foregroundStyle(Theme.warning)
            }

        case .verifying:
            Label("確かめています", systemImage: "hourglass")
                .foregroundStyle(.secondary)

        case .done:
            Label("終わりました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)

        case .verificationFailed(let reason):
            Label("確かめられませんでした: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
        }
    }
}

/// 値をコピーするボタン
struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
            Pasteboard.copy(value)
            copied = true
        }
        .labelStyle(.iconOnly)
        .sensoryFeedback(.success, trigger: copied)
    }
}

/// クリップボード（iOS と macOS で API が違う）
enum Pasteboard {
    static func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
