import SwiftUI

/// 人に渡された失敗。何が起きて何を試したかと、その場で選べる操作を出す（GitHub を開かずに済ませる）
struct BlockerSection: View {
    let epic: Epic
    let blocker: Blocker
    let onAskText: (TextRequest) -> Void

    @Environment(ClientStore.self) private var store
    @State private var isConfirmingDiscard = false

    var body: some View {
        CardSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TagLabel(text: blocker.category.label, tint: Theme.danger)
                    Spacer()
                    Text(RelativeTime.string(blocker.occurredAt, now: store.currentDate()))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(blocker.title)
                    .rowFont(.title)
                Text(blocker.summary)
                    .appFont(.subheadline)
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
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                            Text(attempt.outcome)
                                .appFont(.subheadline)
                        }
                    }
                }
            }
            actions
                .disabled(store.isReflecting(reflectionTargets))
            // 選んだ対処が反映されるまでの様子と、断られた理由（一時停止・引き継ぎの様子は epic の上に出す）
            ReflectionStatusView(.blocker(epicID: epic.id))
        } header: {
            Text("対処が要ります")
        } footer: {
            Text("自動の対処を使い切ったので、選んでもらうまで止めています")
        }
    }

    /// ここで選べる操作の対象（やり直す・やめる、一時停止・引き継ぎ）
    private var reflectionTargets: [IntentTarget] {
        [.blocker(epicID: epic.id), .epicControl(epicID: epic.id)]
    }

    private var discardMessage: String {
        guard let subject = blocker.subject else {
            return "epic ごとやめます。元に戻せません"
        }
        return "\(subject)をやめると先に進めないので、epic ごとやめます。元に戻せません"
    }

    /// 対象を付けた意図（送り直すまでに対象が替わっていたら、窓口が送らない）
    private func intent(_ action: Blocker.Action) -> HumanIntent {
        .resolveBlocker(epicID: epic.id, action: action, instruction: "", target: blocker.target)
    }

    /// 送れない操作（状態リポジトリでは段階 3 の操作）は出さない
    private var sendableActions: [Blocker.Action] {
        blocker.actions.filter { action in
            switch action {
            case .handOver:
                store.supports(.handOver(epicID: epic.id, macID: ""))

            case .pause:
                store.supports(.pause(epicID: epic.id))

            case .fixWithInstruction, .retry, .resumeAfterFix, .cancelJob, .discard:
                store.supports(intent(action))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        ForEach(sendableActions, id: \.self) { action in
            switch action {
            case .fixWithInstruction:
                Button("指示を添えて直させる", systemImage: "text.bubble") {
                    onAskText(TextRequest(title: "指示を添えて直させる", prompt: "どう直してほしいか", purpose: .blockerInstruction(epicID: epic.id)))
                }

            case .retry:
                Button("そのままもう一度試す", systemImage: "arrow.clockwise") {
                    Task { await store.send(intent(.retry)) }
                }

            case .resumeAfterFix:
                Button("直したので再開する", systemImage: "play") {
                    Task { await store.send(intent(.resumeAfterFix)) }
                }

            case .handOver:
                HandOverMenu(epic: epic)

            case .pause:
                Button("一時停止する", systemImage: "pause") {
                    Task { await store.send(.pause(epicID: epic.id)) }
                }

            case .cancelJob:
                Button("\(blocker.subject ?? "この作業")をやめる", systemImage: "xmark.circle") {
                    Task { await store.send(intent(.cancelJob)) }
                }

            case .discard:
                // 一覧の Section に付けると行ごとに付くので、ボタンに付ける
                Button("やめる…", systemImage: "xmark.octagon", role: .destructive) { isConfirmingDiscard = true }
                    .confirmationDialog("「\(epic.title)」をやめますか？", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("やめる", role: .destructive) {
                            Task { await store.send(intent(.discard)) }
                        }
                    } message: {
                        Text(discardMessage)
                    }
            }
        }
    }
}
