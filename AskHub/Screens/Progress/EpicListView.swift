import SwiftUI

/// 「進行中」。epic を、人が待たれているもの・機械が進めているもの・終わったものに分けて並べる
struct EpicListView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let epics = (store.snapshot?.epics ?? []).sorted { $0.updatedAt > $1.updatedAt }
        let active = epics.filter(\.isActive)
        let waiting = active.filter(EpicStatus.waitsForYou)
        let working = active.filter { !EpicStatus.waitsForYou($0) }
        let finished = epics.filter { !$0.isActive }
        RouteList(selection: selection) {
            if !waiting.isEmpty {
                Section("あなた待ち · \(waiting.count)") {
                    ForEach(waiting) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
            if !working.isEmpty {
                Section("機械が進めています · \(working.count)") {
                    ForEach(working) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
            if !finished.isEmpty {
                Section("終わったもの") {
                    ForEach(finished) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
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
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    StageDots(stage: epic.stage, isBlocked: epic.blocker != nil)
                }
                Text(store.repository(epic.repositoryID)?.appName ?? epic.repositoryID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(lines.prefix(2).enumerated()), id: \.offset) { _, line in
                    EpicStatusLabel(line: line)
                        .font(.footnote)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 「いま」の 1 行。人が待たれているものは色を付ける
struct EpicStatusLabel: View {
    let line: EpicStatusLine

    /// Mac の一覧で選んだ行（濃い背景）では、色を付けずに読みやすくする
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        Label(line.text, systemImage: line.systemImage)
            .foregroundStyle(backgroundProminence == .increased ? Color.primary : color)
            .lineLimit(2)
    }

    private var color: Color {
        switch line.owner {
        case .you: line.systemImage == "exclamationmark.triangle.fill" ? Theme.danger : Theme.accent
        case .machine: .secondary
        case .finished: Theme.success
        }
    }
}

/// 一覧の行の、段階を表す小さな点
struct StageDots: View {
    let stage: Epic.Stage
    var isBlocked = false

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
        if index < current || stage == .done {
            return Theme.success
        }
        if index == current {
            return isBlocked ? Theme.danger : Theme.accent
        }
        return .secondary.opacity(0.3)
    }
}
