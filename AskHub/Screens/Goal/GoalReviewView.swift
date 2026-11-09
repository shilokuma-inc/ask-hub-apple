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
            revisionSections(goal)
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

    /// 直している途中の指示と、最後の修正で反映しなかった指示
    @ViewBuilder private func revisionSections(_ goal: Goal) -> some View {
        if let request = goal.revisionRequest {
            CardSection {
                Label("Claude がゴールを直しています: \(request)", systemImage: "pencil")
                    .foregroundStyle(.secondary)
            }
        }
        if !goal.notApplied.isEmpty {
            CardSection {
                ForEach(goal.notApplied, id: \.self) { Text($0) }
            } header: {
                Text("反映しなかった指示")
            } footer: {
                Text("決まったこと（回答）を変える指示は、ゴールの修正では反映しません。回答を変えてから直してもらってください")
            }
        }
    }

    /// 下の帯。開始か直してほしいを送ったら、反映されるまで両方を押せなくし、反映中か断られた理由を出す
    @ViewBuilder private func startBar(_ epic: Epic, _ goal: Goal) -> some View {
        let target = IntentTarget.goal(epicID: epic.id)
        let isReflecting = store.isReflecting([target])
        if epic.stage == .goal {
            VStack(spacing: 6) {
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
                .disabled(isReflecting)
                // 直してほしいを送ったら、司令塔が受け付けるまで両方を押せなくし、その間は小さな印だけを出す
                ReflectionStatusView(target, showsSyncBadge: true)
                    .frame(maxWidth: 520)
                    .padding(.horizontal)
            }
            .padding(.vertical, 10)
        } else if epic.isActive, let line = progressLine(epic) {
            // 開始した後は、司令塔が受け取ったか・どこまで進んだかを出し、epic の画面で続きを見られるようにする。
            // 司令塔がしばらく受け取っていない・断ったときは、その理由も上に出す（同期を待つ間は、行の小さな印だけ）
            VStack(spacing: 8) {
                ReflectionStatusView(target, framed: true)
                    .padding(.horizontal, 16)
                progressLink(epic, line)
            }
        }
    }

    /// 開始した後の「いま」の 1 行と、epic の画面へのリンク
    private func progressLink(_ epic: Epic, _ line: EpicStatusLine) -> some View {
        NavigationLink(value: AppRoute.epic(epic.id)) {
            HStack(spacing: 10) {
                EpicStatusLabel(line: line)
                ReflectionBadge([.goal(epicID: epic.id)], syncOnly: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .appFont(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 開始した後の「いま」の最初の 1 行
    private func progressLine(_ epic: Epic) -> EpicStatusLine? {
        guard let snapshot = store.snapshot else {
            return nil
        }
        return EpicStatus.lines(for: epic, in: snapshot, now: store.currentDate()).first
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
    @State private var sending = SheetSendState()

    var body: some View {
        let macs = store.snapshot?.startableMacs ?? []
        let lastMacID = store.repository(epic.repositoryID)?.lastMacID
        let defaultMacID = store.snapshot?.defaultStartMacID(for: epic.repositoryID)
        NavigationStack {
            List(selection: $selectedMacID) {
                if sending.showsStatus {
                    CardSection {
                        SheetSendStatus(state: sending) { start() }
                    }
                }
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
            .disabled(sending.isSending)
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
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("開始", isSending: sending.isSending) { isConfirming = true }
                        .disabled(selectedMacID == nil)
                }
            }
            .confirmationDialog("「\(epic.title)」を開始しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("\(store.mac(selectedMacID)?.name ?? "") で開始する") { start() }
            } message: {
                Text("開始した後は回答を変えられません。変えたいことは最終 PR への指示として出します")
            }
        }
        .sheetSending(sending)
    }

    /// 送る。送り始めたら（同じものを送ってあったときも）すぐ閉じ、epic は開始した形になる。送れなければ理由を出して残る
    private func start() {
        guard let macID = selectedMacID else {
            return
        }
        if sending.submit(.start(epicID: epic.id, macID: macID), in: store) {
            dismiss()
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
            Text("空き \(ByteFormat.string(mac.freeBytes)) · \(mac.loadText)")
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
