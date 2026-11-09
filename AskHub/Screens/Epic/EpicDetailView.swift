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
                Text(discardMessage(epic))
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
                    StageTrackerView(stage: epic.stage, isBlocked: epic.blocker != nil, isAbandoned: epic.isAbandoned)
                }
                .padding(.vertical, 4)
            }
            if !lines.isEmpty {
                CardSection {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if let route = line.route, line.owner == .you {
                            NavigationLink(value: route) { EpicStatusLabel(line: line, lineLimit: nil) }
                        } else {
                            EpicStatusLabel(line: line, lineLimit: nil)
                        }
                    }
                } header: {
                    // 依頼・epic の操作と、送った後に消えた欄（対処・分け方）への操作は、同期を待つ間ここに小さな印を出す
                    HStack(spacing: 6) {
                        Text("いま")
                        ReflectionBadge(Self.epicTargets(epic), syncOnly: true)
                    }
                }
            }
            // 依頼・epic の操作（一時停止・再開・引き継ぎ・やめる）と、送った後に消えた欄（対処・分け方）への操作は、
            // 司令塔がしばらく受け取っていない・断ったときに、その理由をここに出す
            if store.needsAttention(Self.epicTargets(epic)) {
                CardSection {
                    ReflectionStatusView(Self.epicTargets(epic))
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

    /// epic の上に様子を出す操作の対象。依頼・一時停止・再開・引き継ぎ・やめると、
    /// 送った結果を先に当てると欄ごと消える対処（やり直す・やめる）と分け方（このまま進める）は、欄が無い間だけここに出す
    static func epicTargets(_ epic: Epic) -> [IntentTarget] {
        var targets: [IntentTarget] = [.request(epicID: epic.id), .epicControl(epicID: epic.id)]
        if epic.blocker == nil {
            targets.append(.blocker(epicID: epic.id))
        }
        if epic.split == nil {
            targets.append(.split(epicID: epic.id))
        }
        return targets
    }

    private func discardMessage(_ epic: Epic) -> String {
        guard epic.stage >= .implementing else {
            return "開始する前なので、作業ブランチや子 PR はまだありません。元に戻せません"
        }
        return "作業ブランチと子 PR は片付けます。元に戻せません"
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

    @Environment(ClientStore.self) private var store

    var body: some View {
        if !epic.questions.isEmpty {
            CardSection("質問 · \(epic.questions.filter(\.isSettled).count) / \(epic.questions.count) が決まりました") {
                // やめた epic の質問には答えない（あなたの番・まとめて答える札と同じ）
                if !epic.answerableQuestions.isEmpty, epic.stage == .questions, epic.isActive {
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
                        HStack(spacing: 6) {
                            Text("版 \(goal.version) · タスク \(goal.tasks.count)")
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                            ReflectionBadge([.goal(epicID: epic.id)])
                        }
                    }
                }
            }
        }
        if !epic.humanTasks.isEmpty {
            CardSection("人がする作業") {
                ForEach(epic.humanTasks) { task in
                    NavigationLink(value: AppRoute.humanTask(epicID: epic.id, taskID: task.id)) {
                        HStack(spacing: 6) {
                            Label(task.title, systemImage: task.needsHuman ? "wrench.fill" : "checkmark.circle.fill")
                                .foregroundStyle(task.needsHuman ? Theme.warning : Theme.success)
                            ReflectionBadge([.humanTask(epicID: epic.id, taskID: task.id)])
                        }
                    }
                }
            }
        }
        if !epic.tasks.isEmpty || epic.workspace != nil {
            CardSection("タスク · \(epic.doneTaskCount) / \(epic.tasks.count) 完了") {
                if let workspace = epic.workspace {
                    WorkspaceRow(workspace: workspace)
                }
                ForEach(epic.tasks) { task in
                    TaskRow(task: task, repository: store.repository(epic.repositoryID))
                }
            }
        }
        if let review = epic.finalReview {
            CardSection("最終 PR") {
                NavigationLink(value: AppRoute.finalReview(epic.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((["#\(review.pullRequestNumber)"] + [review.lineChanges].compactMap(\.self)).joined(separator: " · "))
                        HStack(spacing: 6) {
                            Text("判断の確認 \(review.reviewedCount) / \(review.decisions.count) · 実機の確認 \(review.verifications.count)")
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                            ReflectionBadge(finalTargets(review))
                        }
                    }
                }
            }
        }
    }
}

private extension EpicStageSections {
    /// 最終 PR への操作の対象（マージの承認・指示と、判断のカードへの答え）
    func finalTargets(_ review: FinalReview) -> [IntentTarget] {
        [.finalPullRequest(epicID: epic.id)] + review.decisions.map { .decision(epicID: epic.id, decisionID: $0.id) }
    }
}

/// 質問の 1 行（状態・依存先・依存される質問）。回答を送ったら、反映されるまで印を出す（断られた理由は、開いたシートと帯に出す）
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
                ReflectionBadge([.question(epicID: epic.id, questionID: question.id)])
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
            guard epic.isActive else {
                return "見直しの間にやめました"
            }
            return isWorking(on: .reviewing(question.id)) ? "依存先が決まったので、Claude が見直しています" : "見直しが止まっています（対処が要ります）"

        case .awaitingExplanation:
            guard epic.isActive else {
                return "説明を待つ間にやめました"
            }
            return isWorking(on: .explaining(question.id)) ? "Claude が説明を書いています" : "説明が止まっています（対処が要ります）"

        case .open:
            let dependents = epic.questions.dependents(of: question).map(\.id)
            return dependents.isEmpty ? "未回答" : "未回答 · この回答で \(dependents.joined(separator: "・")) が決まります"
        }
    }

    /// 機械がその作業をしているか。人に渡されて止まっている作業は「いま」に出ない
    private func isWorking(on kind: EpicActivity.Kind) -> Bool {
        epic.activities.contains { $0.kind == kind }
    }
}

/// 段取りの最初の行（作業場所の用意）
private struct WorkspaceRow: View {
    let workspace: Epic.Workspace

    var body: some View {
        StepRow(symbol: symbol, title: "作業場所の用意", detail: detail)
    }

    private var symbol: StepSymbol {
        switch workspace {
        case .pending: StepSymbol(name: "circle", color: .secondary)
        case .preparing: StepSymbol(name: "folder.circle.fill", color: Theme.accent)
        case .failed: StepSymbol(name: "exclamationmark.circle.fill", color: Theme.danger)
        case .ready: StepSymbol(name: "checkmark.circle.fill", color: Theme.success)
        }
    }

    private var detail: String {
        switch workspace {
        case .pending: "司令塔が開始を受け取るのを待っています"
        case .preparing: "作業ブランチを作っています"
        case .failed: "止まっています（対処が要ります）"
        case .ready(let branch?): "作業ブランチ \(branch)"
        case .ready(nil): "用意できました"
        }
    }
}

/// タスクの 1 行。進めているタスクは段階を出し、子 PR は GitHub で開ける
private struct TaskRow: View {
    let task: EpicTask
    let repository: TargetRepository?

    var body: some View {
        StepRow(symbol: symbol, title: "\(task.number). \(task.title)", detail: detail) {
            if let number = task.pullRequest {
                if let url = repository?.pullRequestURL(number) {
                    Link("#\(number)", destination: url)
                        .appFont(.caption, weight: .semibold)
                        .accessibilityLabel("子 PR #\(number) を開く")
                } else {
                    Text("#\(number)").appFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: StepSymbol {
        switch task.state {
        case .pending: StepSymbol(name: "circle", color: .secondary)
        case .locked: StepSymbol(name: "lock.fill", color: .secondary)
        case .inProgress(.reviewing?): StepSymbol(name: "eye.circle.fill", color: Theme.accent)
        case .inProgress(.fixing?): StepSymbol(name: "arrow.triangle.2.circlepath.circle.fill", color: Theme.warning)
        case .inProgress(.waitingForAnswer?): StepSymbol(name: "questionmark.circle.fill", color: Theme.warning)
        case .inProgress: StepSymbol(name: "hammer.circle.fill", color: Theme.accent)
        case .failed: StepSymbol(name: "exclamationmark.circle.fill", color: Theme.danger)
        case .done: StepSymbol(name: "checkmark.circle.fill", color: Theme.success)
        }
    }

    private var detail: String? {
        switch task.state {
        case .pending: nil
        case .locked(let reason): reason
        case .inProgress(nil): "進めています"
        case .inProgress(.implementing?): "実装しています"
        case .inProgress(.reviewing?): "子 PR のチェックを待って、レビューしています"
        case let .inProgress(.fixing(_, round, reason)?): "\(EpicStatus.fixLabel(reason))を直しています（\(round) 回目）"
        case .inProgress(.waitingForAnswer(let question, _)?): "途中の質問 \(question) の回答を待っています"
        case .failed: "止まっています（対処が要ります）"
        case .done: "マージしました"
        }
    }
}

/// 段取りの行の印
private struct StepSymbol {
    var name: String
    var color: Color
}

/// 段取りの 1 行（印・題・いまの段階・右端の付け足し）
private struct StepRow<Accessory: View>: View {
    let symbol: StepSymbol
    let title: String
    let detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).appFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension StepRow where Accessory == EmptyView {
    init(symbol: StepSymbol, title: String, detail: String?) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
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

/// epic の操作（一時停止・再開・引き継ぎ・やめる）
private struct EpicMenu: ToolbarContent {
    let epic: Epic
    @Binding var isConfirmingDiscard: Bool

    @Environment(ClientStore.self) private var store

    var body: some ToolbarContent {
        // 一時停止・再開・引き継ぎは、開始した後（実装・最終 PR）だけ。送れない操作は出さない。1 つも無ければメニューごと出さない
        let isStarted = epic.isActive && epic.stage >= .implementing
        let canPause = isStarted && !epic.isPaused && store.supports(.pause(epicID: epic.id))
        let canResume = isStarted && epic.isPaused && store.supports(.resume(epicID: epic.id))
        let canHandOver = isStarted && store.supports(.handOver(epicID: epic.id, macID: ""))
        // 一時停止していない epic は、Mac で動いている作業が終わるまで引き継げない（司令塔が断る）。そのときは一時停止を促す
        let handOverNeedsPause = isStarted && !canHandOver && canPause
        let canDiscard = epic.isActive && store.supports(.discard(epicID: epic.id))
        // 前の操作の同期を待つ間は、ほかの操作も押せなくする（同期待ちの印は epic の画面の「いま」に出す）
        let isReflecting = store.isReflecting([.epicControl(epicID: epic.id)])
        ToolbarItem(placement: .primaryAction) {
            if canPause || canResume || canHandOver || canDiscard {
                Menu("操作", systemImage: "ellipsis.circle") {
                    if canPause {
                        Button("一時停止する", systemImage: "pause") {
                            Task { await store.send(.pause(epicID: epic.id)) }
                        }
                    }
                    if canResume {
                        Button("再開する", systemImage: "play") {
                            Task { await store.send(.resume(epicID: epic.id)) }
                        }
                    }
                    if canHandOver {
                        HandOverMenu(epic: epic)
                    } else if handOverNeedsPause {
                        Button("ほかの Mac に引き継ぐ（動いている作業があるので、先に一時停止します）", systemImage: "arrow.right.arrow.left") {}
                            .disabled(true)
                    }
                    if canDiscard {
                        Divider()
                        Button("やめる…", systemImage: "xmark.octagon", role: .destructive) { isConfirmingDiscard = true }
                    }
                }
                .disabled(isReflecting)
            }
        }
    }
}

/// ほかの Mac への引き継ぎ（いま回している Mac のほかのすべての Mac）。
/// オフラインの Mac も選べる（戻ると、最後に push したところから続きを動かす）。ジョブを受けない Mac（自己診断の問題など）は選べない
struct HandOverMenu: View {
    let epic: Epic

    @Environment(ClientStore.self) private var store

    var body: some View {
        let macs = store.snapshot?.macs.filter { $0.id != epic.macID } ?? []
        Menu("ほかの Mac に引き継ぐ", systemImage: "arrow.right.arrow.left") {
            ForEach(macs) { mac in
                Button(Self.label(of: mac)) {
                    Task { await store.send(.handOver(epicID: epic.id, macID: mac.id)) }
                }
                .disabled(mac.refusalReason != nil)
            }
            if macs.isEmpty {
                Text("引き継げる Mac がありません")
            }
        }
    }

    /// Mac の名前に、選べない理由かオフラインであることを添える
    static func label(of mac: Mac) -> String {
        if let reason = mac.refusalReason {
            return "\(mac.name)（\(mac.isOnline ? "" : "オフライン・")\(reason)）"
        }
        return mac.isOnline ? mac.name : "\(mac.name)（オフライン。戻ると続きから動きます）"
    }
}
