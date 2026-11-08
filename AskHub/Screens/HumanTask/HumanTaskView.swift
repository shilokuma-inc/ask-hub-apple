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

    var body: some View {
        if let epic = store.epic(epicID), let task = epic.humanTask(taskID) {
            content(epic, task)
        } else {
            ContentUnavailableView("この作業は見つかりません", systemImage: "wrench")
        }
    }

    private func content(_ epic: Epic, _ task: HumanTask) -> some View {
        List {
            CardSection {
                AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: epic.title, iconSize: 40)
                Text(task.title).rowFont(.title)
                Text(task.why).foregroundStyle(.secondary)
                stateLabel(task.state, epic: epic, task: task)
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
            }
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("人がする作業")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
            pick(result)
        }
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
                    Text(Int64(file.size).formatted(.byteCount(style: .file)))
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

    /// GitHub の Secrets に入れる作業。値は AskHub では受け取らず、人が GitHub の設定画面で入れてから「終わった」を押す
    private func secretSection(_ epic: Epic, _ task: HumanTask, name: String, repository: String) -> some View {
        CardSection {
            LabeledContent("Secrets の名前") {
                HStack {
                    Text(name)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    CopyButton(value: name)
                }
            }
            if let url = Self.secretsSettingsURL(repository) {
                Link(destination: url) {
                    Label("GitHub の Secrets の設定を開く", systemImage: "safari")
                }
            }
            completeButton(epic, task)
        } header: {
            Text("渡すもの")
        } footer: {
            let place = "GitHub の \(repository.isEmpty ? "リポジトリ" : repository) の Settings → Secrets and variables → Actions"
            Text("\(place) で、「\(name)」に値を入れてから押してください。AskHub は値を受け取りません")
        }
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
