import SwiftUI

/// 「進行中」。epic を、人が待たれているもの・一時停止しているもの・機械が進めているもの・終わったものに分けて並べる
struct EpicListView: View {
    /// 終わったものは、新しい順にこの件数だけ出す。それより前のものは「すべて見る」から見返す（増え続けて一覧が長くならないように。ユーザーが決めた。2026-11-11）
    static let finishedLimit = 10

    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let epics = (store.snapshot?.epics ?? []).sorted { $0.updatedAt > $1.updatedAt }
        let active = epics.filter(\.isActive)
        let waiting = active.filter(EpicStatus.waitsForYou)
        let paused = active.filter(EpicStatus.isPausedByYou)
        let working = active.filter { !EpicStatus.waitsForYou($0) && !EpicStatus.isPausedByYou($0) }
        let finished = epics.filter { !$0.isActive }
        RouteList(selection: selection) {
            if !waiting.isEmpty {
                CardSection("あなた待ち · \(waiting.count)") {
                    ForEach(waiting) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
            if !paused.isEmpty {
                CardSection("一時停止中 · \(paused.count)") {
                    ForEach(paused) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
            if !working.isEmpty {
                CardSection("機械が進めています · \(working.count)") {
                    ForEach(working) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
            if !finished.isEmpty {
                CardSection("終わったもの") {
                    ForEach(finished.prefix(Self.finishedLimit)) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                    if finished.count > Self.finishedLimit {
                        NavigationLink(value: AppRoute.finishedEpics) {
                            LabeledContent("すべて見る", value: "\(finished.count) 件")
                        }
                    }
                }
            }
        }
        .overlay {
            LoadStateOverlay(isEmpty: epics.isEmpty, empty: ContentUnavailableView {
                Label("進めているものはありません", systemImage: "tray")
            } description: {
                Text("＋ から依頼すると、ここに並びます")
            })
        }
        .pastelBackground()
        .navigationTitle("進行中")
        .toolbar { SectionToolbar() }
        .refreshable { await store.refresh() }
    }
}

/// epic の 1 行。アプリのアイコン・段階の点・いまの 1 行を出す
struct EpicRow: View {
    let epic: Epic

    @Environment(ClientStore.self) private var store

    var body: some View {
        let lines = store.snapshot.map { EpicStatus.lines(for: epic, in: $0, now: store.currentDate()) } ?? []
        HStack(alignment: .top, spacing: 12) {
            AppIconView(repository: store.repository(epic.repositoryID), size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(epic.title)
                        .rowFont(.title)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    StageDots(stage: epic.stage, isBlocked: epic.blocker != nil, isAbandoned: epic.isAbandoned)
                }
                HStack(spacing: 6) {
                    Text(store.repository(epic.repositoryID)?.appName ?? epic.repositoryID)
                        .rowFont(.subtitle)
                        .foregroundStyle(.secondary)
                    // この epic への操作のどれかが反映を待っているか、断られた
                    ReflectionBadge(epicID: epic.id)
                }
                ForEach(Array(lines.prefix(2).enumerated()), id: \.offset) { _, line in
                    EpicStatusLabel(line: line)
                        .rowFont(.detail)
                }
            }
        }
        .compactRow()
        .accessibilityElement(children: .combine)
    }
}

/// 「いま」の 1 行。人が待たれているものは色を付ける
struct EpicStatusLabel: View {
    let line: EpicStatusLine
    /// 一覧の行では 2 行までにする。epic の画面では絞らない（nil）
    var lineLimit: Int? = 2

    /// Mac の一覧で選んだ行（濃い背景）では、色を付けずに読みやすくする
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text)
                    .lineLimit(lineLimit)
                if let detail = line.detail {
                    Text(detail)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: line.systemImage)
        }
        .foregroundStyle(backgroundProminence == .increased ? Color.primary : color)
    }

    private var color: Color {
        switch line.owner {
        case .you: line.systemImage == "exclamationmark.triangle.fill" ? Theme.danger : Theme.accent
        case .machine: .secondary
        case .finished: Theme.success
        case .abandoned: .secondary
        }
    }
}

/// 一覧の行の、段階を表す小さな点
struct StageDots: View {
    let stage: Epic.Stage
    var isBlocked = false
    /// やめた段階の点は、色を付けない
    var isAbandoned = false

    var body: some View {
        let current = Self.index(of: stage)
        HStack(spacing: 3) {
            ForEach(0..<6) { index in
                Circle()
                    .fill(color(index: index, current: current))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    static func index(of stage: Epic.Stage) -> Int {
        switch stage {
        case .request: 0
        case .questions: 1
        case .preflight, .goal: 2
        case .implementing: 3
        case .finalReview: 4
        case .done: 5
        }
    }

    private func color(index: Int, current: Int) -> Color {
        if isAbandoned && index == current {
            return .secondary
        }
        if index < current || stage == .done {
            return Theme.success
        }
        if index == current {
            return isBlocked ? Theme.danger : Theme.accent
        }
        return .secondary.opacity(0.3)
    }
}
