import SwiftUI

/// ゴールの確認と開始。人が見て「開始」か「直してほしい」を選ぶ（回答だけでループは始まらない）
struct GoalReviewView: View {
    let epicID: Epic.ID

    @Environment(ClientStore.self) private var store
    @State private var textRequest: TextRequest?
    @State private var isChoosingMac = false

    var body: some View {
        if let epic = store.epic(epicID), let goal = epic.goal {
            content(epic, goal)
        } else {
            ContentUnavailableView("ゴールはまだありません", systemImage: "flag")
        }
    }

    private func content(_ epic: Epic, _ goal: Goal) -> some View {
        List {
            Section {
                AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: "ゴール（版 \(goal.version)）", iconSize: 40)
                Text(goal.summary)
                    .font(.headline)
            }
            if let request = goal.revisionRequest {
                Section {
                    Label("Claude がゴールを直しています: \(request)", systemImage: "pencil")
                        .foregroundStyle(.secondary)
                }
            }
            pointsSection("決まったこと", goal.decided)
            pointsSection("おまかせにしたこと", goal.delegated, footer: "最終 PR の「人が決めていない判断」で見直せます")
            listSection("やらないこと", goal.notDoing)
            listSection("完了の条件", goal.doneCriteria)
            Section("タスク · \(goal.tasks.count)") {
                ForEach(Array(goal.tasks.enumerated()), id: \.offset) { index, task in
                    HStack {
                        Text("\(index + 1). \(task.title)")
                        if task.humanTaskID != nil {
                            Spacer()
                            TagLabel(text: "人がする作業が前提", tint: .orange)
                        }
                    }
                }
            }
            if !epic.humanTasks.isEmpty {
                Section("人がする作業") {
                    ForEach(epic.humanTasks) { task in
                        NavigationLink(value: AppRoute.humanTask(epicID: epic.id, taskID: task.id)) {
                            Label(task.title, systemImage: "wrench.fill")
                        }
                    }
                }
            }
        }
        .navigationTitle(epic.title)
        .hidesTabBar()
        .safeAreaBar(edge: .bottom) { startBar(epic, goal) }
        .modifier(GoalSheets(epic: epic, textRequest: $textRequest, isChoosingMac: $isChoosingMac))
    }

    @ViewBuilder private func startBar(_ epic: Epic, _ goal: Goal) -> some View {
        if epic.stage == .goal {
            HStack(spacing: 12) {
                Button("直してほしい", systemImage: "pencil") {
                    textRequest = TextRequest(title: "ゴールを直してほしい", prompt: "どう直してほしいか", purpose: .goalRevision(epicID: epic.id))
                }
                .buttonStyle(.glass)
                Button("開始…", systemImage: "play.fill") { isChoosingMac = true }
                    .buttonStyle(.glassProminent)
                    .disabled(goal.isRevising)
            }
            .controlSize(.large)
            .padding(.vertical, 10)
        }
    }

    private func pointsSection(_ title: String, _ points: [Goal.Point], footer: String? = nil) -> some View {
        Section {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline) {
                    Text(point.text)
                    if let id = point.questionID {
                        Spacer()
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            if points.isEmpty {
                Text("ありません").foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private func listSection(_ title: String, _ items: [String]) -> some View {
        Section(title) {
            ForEach(items, id: \.self) { Text($0) }
        }
    }
}

/// ゴールの画面のシート（直してほしい・開始）
private struct GoalSheets: ViewModifier {
    let epic: Epic
    @Binding var textRequest: TextRequest?
    @Binding var isChoosingMac: Bool

    @Environment(ClientStore.self) private var store

    func body(content: Content) -> some View {
        content
            .sheet(item: $textRequest) { request in
                TextRequestSheet(request: request) { text in
                    textRequest = nil
                    Task { await store.send(request.intent(text: text)) }
                } onCancel: {
                    textRequest = nil
                }
            }
            .sheet(isPresented: $isChoosingMac) {
                StartSheet(epic: epic)
            }
    }
}

/// 開始のときに回す Mac を選ぶ。そのリポジトリを回してよい Mac だけを出す
struct StartSheet: View {
    let epic: Epic

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMacID: Mac.ID?
    @State private var isConfirming = false

    var body: some View {
        let macs = store.snapshot?.allowedMacs(for: epic.repositoryID) ?? []
        NavigationStack {
            List(selection: $selectedMacID) {
                Section {
                    ForEach(macs) { mac in
                        MacChoiceRow(mac: mac)
                            .tag(mac.id)
                            .selectionDisabled(mac.refusalReason != nil)
                    }
                } header: {
                    Text("どの Mac で回しますか")
                } footer: {
                    Text("このリポジトリを回してよい Mac だけを出しています。オフラインの Mac を選ぶと、戻ったときに始まります")
                }
            }
            .navigationTitle("開始する")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") { isConfirming = true }
                        .disabled(selectedMacID == nil)
                }
            }
            .confirmationDialog("「\(epic.title)」を開始しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("\(store.mac(selectedMacID)?.name ?? "") で開始する") {
                    guard let macID = selectedMacID else {
                        return
                    }
                    Task {
                        await store.send(.start(epicID: epic.id, macID: macID))
                        dismiss()
                    }
                }
            } message: {
                Text("開始した後は回答を変えられません。変えたいことは最終 PR への指示として出します")
            }
        }
    }
}

/// Mac を選ぶ行（オンラインか・空き容量・負荷・契約）
struct MacChoiceRow: View {
    let mac: Mac

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mac.name).font(.headline)
                Spacer()
                ConnectionBadge(mac: mac)
            }
            Text("空き \(ByteFormat.string(mac.freeBytes)) · 負荷 \(Int(mac.load * 100))% · \(mac.contract.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = mac.refusalReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
