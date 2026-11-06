import SwiftUI

/// 人がする作業（AskHub だけではできない作業）。手順・開くページ・渡すものを出し、終わったら知らせる
struct HumanTaskView: View {
    let epicID: Epic.ID
    let taskID: HumanTask.ID

    @Environment(ClientStore.self) private var store
    @State private var secret = ""
    @State private var isConfirmingSecret = false
    @FocusState private var isEditingSecret: Bool

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
        .keyboardDoneButton($isEditingSecret)
        .confirmationDialog("秘密の値を GitHub の Secrets に入れますか？", isPresented: $isConfirmingSecret, titleVisibility: .visible) {
            Button("入れる") {
                secret = ""
                Task { await store.send(.submitSecret(epicID: epic.id, taskID: task.id)) }
            }
        } message: {
            Text("暗号化して入れます。AskHub にもリポジトリにも残しません")
        }
    }

    @ViewBuilder private func deliverableSection(_ epic: Epic, _ task: HumanTask) -> some View {
        switch task.deliverable {
        case .none:
            CardSection {
                Button("終わった", systemImage: "checkmark.circle") {
                    Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id)) }
                }
            } footer: {
                Text("押すと、ワーカーが確かめられる範囲で確かめてから、前提にしているタスクのロックを外します")
            }

        case .file(let description):
            CardSection {
                Button("ファイルを渡す…", systemImage: "doc.badge.plus") {
                    Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id)) }
                }
            } footer: {
                Text(description)
            }

        case let .secret(name, repository):
            CardSection {
                SecureField(name, text: $secret)
                    .focused($isEditingSecret)
                Button("Secrets に入れる…", systemImage: "lock") { isConfirmingSecret = true }
                    .disabled(secret.isEmpty)
            } header: {
                Text("渡すもの")
            } footer: {
                Text("\(repository) の Actions の Secrets「\(name)」に入れます")
            }
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
