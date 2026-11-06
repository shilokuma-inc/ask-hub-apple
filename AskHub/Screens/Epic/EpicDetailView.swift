import SwiftUI

/// epic の画面。段階の帯と「いま誰が待っているか」を一番上に出し、段階ごとの中身を下に並べる
struct EpicDetailView: View {
    let epicID: Epic.ID

    @Environment(ClientStore.self) private var store
    @State private var shownQuestion: Question?
    @State private var textRequest: TextRequest?
    @State private var isConfirmingDiscard = false

    var body: some View {
        if let epic = store.epic(epicID) {
            content(epic)
        } else {
            ContentUnavailableView("この epic は見つかりません", systemImage: "questionmark.folder")
        }
    }

    private func content(_ epic: Epic) -> some View {
        sections(epic)
            .pastelBackground()
            .compactList()
            .navigationTitle(epic.title)
            .toolbar { EpicMenu(epic: epic, isConfirmingDiscard: $isConfirmingDiscard) }
            .confirmationDialog("「\(epic.title)」をやめますか？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("やめる", role: .destructive) {
                    Task { await store.send(.discard(epicID: epic.id)) }
                }
            } message: {
                Text("作業ブランチと子 PR は片付けます。元に戻せません")
            }
            .sheet(item: $shownQuestion) { question in
                QuestionSheet(epic: epic, question: question)
            }
            .sheet(item: $textRequest) { request in
                TextRequestSheet(request: request) { text in
                    textRequest = nil
                    Task { await store.send(request.intent(text: text)) }
                } onCancel: {
                    textRequest = nil
                }
            }
    }

    private func sections(_ epic: Epic) -> some View {
        let lines = store.snapshot.map { EpicStatus.lines(for: epic, in: $0, now: store.currentDate()) } ?? []
        return List {
            CardSection {
                VStack(alignment: .leading, spacing: 14) {
                    AppHeaderView(repository: store.repository(epic.repositoryID), subtitle: subtitle(epic), iconSize: 40)
                    StageTrackerView(stage: epic.stage, isBlocked: epic.blocker != nil)
                }
                .padding(.vertical, 4)
            }
            if !lines.isEmpty {
                CardSection("いま") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if let route = line.route, line.owner == .you {
                            NavigationLink(value: route) { EpicStatusLabel(line: line) }
                        } else {
                            EpicStatusLabel(line: line)
                        }
                    }
                }
            }
            if let blocker = epic.blocker {
                BlockerSection(epic: epic, blocker: blocker) { textRequest = $0 }
            }
            if let split = epic.split {
                SplitSection(epic: epic, split: split)
            }
            EpicStageSections(epic: epic) { shownQuestion = $0 }
            CardSection("依頼") {
                Text(epic.request.summary).rowFont(.title)
                Text(epic.request.body).foregroundStyle(.secondary)
                if epic.request.attachmentCount > 0 {
                    Label("添付 \(epic.request.attachmentCount)", systemImage: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }
            HistorySection(history: epic.history, now: store.currentDate())
        }
    }

    private func subtitle(_ epic: Epic) -> String {
        var parts = ["\(RelativeTime.string(epic.request.requestedAt, now: store.currentDate()))に依頼"]
        if let mac = store.mac(epic.macID) {
            parts.append("\(mac.name) で実装")
        }
        return parts.joined(separator: " · ")
    }
}

/// 段階ごとの中身（質問・ゴール・タスク・人がする作業・最終 PR）
private struct EpicStageSections: View {
    let epic: Epic
    let onShowQuestion: (Question) -> Void

    var body: some View {
        if !epic.questions.isEmpty {
            CardSection("質問 · \(epic.questions.filter(\.isSettled).count) / \(epic.questions.count) が決まりました") {
                if !epic.answerableQuestions.isEmpty, epic.stage == .questions {
                    NavigationLink(value: AppRoute.deck(.questions(epic.id))) {
                        Label("質問に答える（\(epic.answerableQuestions.count)）", systemImage: "rectangle.stack")
                            .rowFont(.title)
                    }
                }
                ForEach(epic.questions) { question in
                    Button { onShowQuestion(question) } label: {
                        QuestionStatusRow(question: question, epic: epic)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if let goal = epic.goal, epic.stage >= .goal {
            CardSection("ゴール") {
                NavigationLink(value: AppRoute.goal(epic.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(goal.summary).lineLimit(3)
                        Text("版 \(goal.version) · タスク \(goal.tasks.count)")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !epic.humanTasks.isEmpty {
            CardSection("人がする作業") {
                ForEach(epic.humanTasks) { task in
                    NavigationLink(value: AppRoute.humanTask(epicID: epic.id, taskID: task.id)) {
                        Label(task.title, systemImage: task.needsHuman ? "wrench.fill" : "checkmark.circle.fill")
                            .foregroundStyle(task.needsHuman ? Theme.warning : Theme.success)
                    }
                }
            }
        }
        if !epic.tasks.isEmpty {
            CardSection("タスク · \(epic.doneTaskCount) / \(epic.tasks.count) 完了") {
                ForEach(epic.tasks) { task in
                    TaskRow(task: task)
                }
            }
        }
        if let review = epic.finalReview {
            CardSection("最終 PR") {
                NavigationLink(value: AppRoute.finalReview(epic.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(review.pullRequestNumber) · +\(review.additions) −\(review.deletions)")
                        Text("判断の確認 \(review.reviewedCount) / \(review.decisions.count) · 実機の確認 \(review.verifications.count)")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// 質問の 1 行（状態・依存先・依存される質問）
struct QuestionStatusRow: View {
    let question: Question
    let epic: Epic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: question.statusSymbol)
                .foregroundStyle(question.statusColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(question.id) \(question.title)")
                    .lineLimit(2)
                Text(detail)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    private var detail: String {
        switch question.state {
        case .answered(let response):
            return "回答: \(question.answeredOption?.label ?? response.note)"

        case .locked:
            return "\(question.dependsOn.joined(separator: "・")) の回答後に答えられます"

        case .reviewing:
            return "依存先が決まったので、Claude が見直しています"

        case .awaitingExplanation:
            return "Claude が説明を書いています"

        case .open:
            let dependents = epic.questions.dependents(of: question).map(\.id)
            return dependents.isEmpty ? "未回答" : "未回答 · この回答で \(dependents.joined(separator: "・")) が決まります"
        }
    }
}

/// タスクの 1 行
private struct TaskRow: View {
    let task: EpicTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(task.number). \(task.title)")
                if case .locked(let reason) = task.state {
                    Text(reason).appFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if case .done(let number?) = task.state {
                Text("#\(number)").appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: (name: String, color: Color) {
        switch task.state {
        case .pending: ("circle", .secondary)
        case .locked: ("lock.fill", .secondary)
        case .inProgress: ("hammer.circle.fill", Theme.accent)
        case .failed: ("exclamationmark.circle.fill", .red)
        case .done: ("checkmark.circle.fill", .green)
        }
    }
}

/// 履歴（新しい順に 5 件、残りは畳む）
private struct HistorySection: View {
    let history: [Epic.HistoryEntry]
    let now: Date

    var body: some View {
        let entries = Array(history.reversed())
        CardSection("履歴") {
            ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                row(entry)
            }
            if entries.count > 5 {
                DisclosureGroup("ほかの \(entries.count - 5) 件") {
                    ForEach(Array(entries.dropFirst(5).enumerated()), id: \.offset) { _, entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: Epic.HistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.text)
                .foregroundStyle(entry.isFailure ? Theme.danger : .primary)
            Spacer(minLength: 8)
            Text(RelativeTime.string(entry.date, now: now))
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .appFont(.subheadline)
    }
}

/// epic の操作（一時停止・引き継ぎ・やめる）
private struct EpicMenu: ToolbarContent {
    let epic: Epic
    @Binding var isConfirmingDiscard: Bool

    @Environment(ClientStore.self) private var store

    var body: some ToolbarContent {
        // 送れない操作（状態リポジトリでは段階 3 の操作）は出さない。1 つも無ければメニューごと出さない
        let canPause = epic.stage == .implementing && store.supports(.pause(epicID: epic.id))
        let canHandOver = epic.stage == .implementing && store.supports(.handOver(epicID: epic.id, macID: ""))
        let canDiscard = epic.isActive && store.supports(.discard(epicID: epic.id))
        ToolbarItem(placement: .primaryAction) {
            if canPause || canHandOver || canDiscard {
                Menu("操作", systemImage: "ellipsis.circle") {
                    if canPause {
                        let isPaused = epic.activities.contains {
                            if case .paused = $0.kind {
                                return true
                            }
                            return false
                        }
                        Button(isPaused ? "再開する" : "一時停止する", systemImage: isPaused ? "play" : "pause") {
                            Task { await store.send(isPaused ? .resume(epicID: epic.id) : .pause(epicID: epic.id)) }
                        }
                    }
                    if canHandOver {
                        HandOverMenu(epic: epic)
                    }
                    if canDiscard {
                        Divider()
                        Button("やめる…", systemImage: "xmark.octagon", role: .destructive) { isConfirmingDiscard = true }
                    }
                }
            }
        }
    }
}

/// ほかの Mac への引き継ぎ（いま回している Mac のほかのすべての Mac。オフラインの Mac は選べない）
struct HandOverMenu: View {
    let epic: Epic

    @Environment(ClientStore.self) private var store

    var body: some View {
        let macs = store.snapshot?.macs.filter { $0.id != epic.macID } ?? []
        Menu("ほかの Mac に引き継ぐ", systemImage: "arrow.right.arrow.left") {
            ForEach(macs) { mac in
                Button("\(mac.name)\(mac.isOnline ? "" : "（オフライン）")") {
                    Task { await store.send(.handOver(epicID: epic.id, macID: mac.id)) }
                }
                .disabled(!mac.isOnline)
            }
            if macs.isEmpty {
                Text("引き継げる Mac がありません")
            }
        }
    }
}
