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
            CardSection {
                AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: "ゴール（版 \(goal.version)）", iconSize: 40)
                Text(goal.summary)
                    .rowFont(.title)
            }
            if let request = goal.revisionRequest {
                CardSection {
                    Label("Claude がゴールを直しています: \(request)", systemImage: "pencil")
                        .foregroundStyle(.secondary)
                }
            }
            pointsSection("決まったこと", goal.decided)
            listSection("やらないこと", goal.notDoing)
            listSection("完了の条件", goal.doneCriteria)
            CardSection("タスク · \(goal.tasks.count)") {
                ForEach(Array(goal.tasks.enumerated()), id: \.offset) { index, task in
                    HStack {
                        Text("\(index + 1). \(task.title)")
                        if task.humanTaskID != nil {
                            Spacer()
                            TagLabel(text: "人がする作業が前提", tint: Theme.warning)
                        }
                    }
                }
            }
            if !epic.humanTasks.isEmpty {
                CardSection("人がする作業") {
                    ForEach(epic.humanTasks) { task in
                        NavigationLink(value: AppRoute.humanTask(epicID: epic.id, taskID: task.id)) {
                            Label(task.title, systemImage: "wrench.fill")
                        }
                    }
                }
            }
        }
        .pastelBackground()
        .compactList()
        .navigationTitle(epic.title)
        .hidesTabBar()
        .safeAreaBar(edge: .bottom) { startBar(epic, goal).keepsControlSize() }
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
        CardSection {
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
        CardSection(title) {
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

/// 開始のときに回す Mac を選ぶ。オンラインの Mac をすべて出し、前回そのリポジトリを回した Mac を選んでおく
struct StartSheet: View {
    let epic: Epic

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMacID: Mac.ID?
    @State private var isConfirming = false

    var body: some View {
        let macs = store.snapshot?.startableMacs ?? []
        let lastMacID = store.repository(epic.repositoryID)?.lastMacID
        let defaultMacID = store.snapshot?.defaultStartMacID(for: epic.repositoryID)
        NavigationStack {
            List(selection: $selectedMacID) {
                CardSection {
                    ForEach(macs) { mac in
                        MacChoiceRow(mac: mac, isLastUsed: mac.id == lastMacID)
                            .tag(mac.id)
                            .selectionDisabled(mac.refusalReason != nil)
                    }
                    if macs.isEmpty {
                        Text("オンラインの Mac がありません").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("どの Mac で回しますか")
                } footer: {
                    Text(defaultMacID == nil ? "オンラインの Mac を出しています" : "オンラインの Mac を出しています。前回このリポジトリを回した Mac を選んであります")
                }
            }
            .onAppear {
                if selectedMacID == nil {
                    selectedMacID = defaultMacID
                }
            }
            .pastelBackground()
            .compactList()
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

/// Mac を選ぶ行（オンラインか・空き容量・負荷・前回このリポジトリを回したか）
struct MacChoiceRow: View {
    let mac: Mac
    var isLastUsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mac.name).rowFont(.title)
                if isLastUsed {
                    TagLabel(text: "前回")
                }
                Spacer()
                ConnectionBadge(mac: mac)
            }
            Text("空き \(ByteFormat.string(mac.freeBytes)) · 負荷 \(Int(mac.load * 100))%")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            if let reason = mac.refusalReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundStyle(Theme.warning)
            }
        }
    }
}
