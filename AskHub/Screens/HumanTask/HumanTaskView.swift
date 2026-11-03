import SwiftUI

/// 人がする作業（AskHub だけではできない作業）。手順・開くページ・渡すものを出し、終わったら知らせる
struct HumanTaskView: View {
    let epicID: Epic.ID
    let taskID: HumanTask.ID

    @Environment(ClientStore.self) private var store
    @State private var secret = ""
    @State private var isConfirmingSecret = false

    var body: some View {
        if let epic = store.epic(epicID), let task = epic.humanTask(taskID) {
            content(epic, task)
        } else {
            ContentUnavailableView("この作業は見つかりません", systemImage: "wrench")
        }
    }

    private func content(_ epic: Epic, _ task: HumanTask) -> some View {
        List {
            Section {
                AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: epic.title, iconSize: 40)
                Text(task.title).font(.headline)
                Text(task.why).foregroundStyle(.secondary)
                stateLabel(task.state, epic: epic, task: task)
            }
            Section("手順") {
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
                Section("開くページ") {
                    ForEach(task.links, id: \.url) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: "safari")
                        }
                    }
                }
            }
            if task.needsHuman {
                deliverableSection(epic, task)
            }
        }
        .navigationTitle("人がする作業")
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
            Section {
                Button("終わった", systemImage: "checkmark.circle") {
                    Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id)) }
                }
            } footer: {
                Text("押すと、ワーカーが確かめられる範囲で確かめてから、前提にしているタスクのロックを外します")
            }

        case .file(let description):
            Section {
                Button("ファイルを渡す…", systemImage: "doc.badge.plus") {
                    Task { await store.send(.completeHumanTask(epicID: epic.id, taskID: task.id)) }
                }
            } footer: {
                Text(description)
            }

        case let .secret(name, repository):
            Section {
                SecureField(name, text: $secret)
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
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

        case .verifying:
            Label("確かめています", systemImage: "hourglass")
                .foregroundStyle(.secondary)

        case .done:
            Label("終わりました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .verificationFailed(let reason):
            Label("確かめられませんでした: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
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
