import SwiftUI

/// 人に渡された失敗。何が起きて何を試したかと、その場で選べる操作を出す（GitHub を開かずに済ませる）
struct BlockerSection: View {
    let epic: Epic
    let blocker: Blocker
    let onAskText: (TextRequest) -> Void

    @Environment(ClientStore.self) private var store

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TagLabel(text: blocker.category.label, tint: Theme.danger)
                    Spacer()
                    Text(RelativeTime.string(blocker.occurredAt, now: store.currentDate()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(blocker.title)
                    .font(.headline)
                Text(blocker.summary)
                    .font(.subheadline)
                if let log = blocker.logExcerpt {
                    ScrollView(.horizontal) {
                        Text(log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.vertical, 4)
            if !blocker.attempts.isEmpty {
                DisclosureGroup("試したこと · \(blocker.attempts.count) 回") {
                    ForEach(blocker.attempts) { attempt in
                        VStack(alignment: .leading, spacing: 2) {
                            let period = "\(RelativeTime.clock(attempt.startedAt))〜\(RelativeTime.clock(attempt.endedAt))"
                            Text("試行 \(attempt.number) · \(attempt.macName) · \(period)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(attempt.outcome)
                                .font(.subheadline)
                        }
                    }
                }
            }
            actions
        } header: {
            Text("対処が要ります")
        } footer: {
            Text("自動の対処を使い切ったので、選んでもらうまで止めています")
        }
    }

    @ViewBuilder private var actions: some View {
        ForEach(blocker.actions, id: \.self) { action in
            switch action {
            case .fixWithInstruction:
                Button("指示を添えて直させる", systemImage: "text.bubble") {
                    onAskText(TextRequest(title: "指示を添えて直させる", prompt: "どう直してほしいか", purpose: .blockerInstruction(epicID: epic.id)))
                }

            case .retry:
                Button("そのままもう一度試す", systemImage: "arrow.clockwise") {
                    Task { await store.send(.resolveBlocker(epicID: epic.id, action: .retry, instruction: "")) }
                }

            case .resumeAfterFix:
                Button("直したので再開する", systemImage: "play") {
                    Task { await store.send(.resolveBlocker(epicID: epic.id, action: .resumeAfterFix, instruction: "")) }
                }

            case .handOver:
                HandOverMenu(epic: epic)

            case .pause:
                Button("一時停止する", systemImage: "pause") {
                    Task { await store.send(.pause(epicID: epic.id)) }
                }

            case .discard:
                EmptyView()
            }
        }
    }
}
