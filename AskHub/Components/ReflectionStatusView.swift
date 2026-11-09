import SwiftUI

/// 送った意図が反映されるまでの様子を、操作した場所（カード・行・ボタンの下）に出す 1 行。
///
/// 反映中・司令塔がしばらく受け取っていない・断られた（理由と閉じるボタン）を出す。何も無ければ何も出さない。
/// 全画面のローディングにはせず、ほかの対象や画面は普段どおり使えるようにする。iOS と macOS で同じ View を使う
struct ReflectionStatusView: View {
    let targets: [IntentTarget]

    @Environment(ClientStore.self) private var store

    init(_ targets: [IntentTarget]) {
        self.targets = targets
    }

    init(_ target: IntentTarget) {
        self.init([target])
    }

    var body: some View {
        if let reflection = store.reflection(for: targets) {
            // 司令塔が受け取らないまま時間がたったことを、読み直しを待たずに出す
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                content(message(reflection))
            }
        }
    }

    private func message(_ reflection: Reflection) -> ReflectionMessage {
        ReflectionMessage.make(
            reflection,
            now: store.currentDate(),
            stallThreshold: store.stallThreshold,
            commanderSeenAt: store.snapshot?.commanderSeenAt
        )
    }

    private func content(_ message: ReflectionMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ReflectionSymbol(tone: message.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .appFont(.footnote, weight: .semibold)
                    .foregroundStyle(message.tone.titleStyle)
                Text(message.detail)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let rejectionID = message.rejectionID {
                Button("閉じる", systemImage: "xmark") { store.dismissRejection(rejectionID) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .appFont(.footnote)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reflection-status")
    }
}

/// 送った意図が反映されるまでの様子の小さな印（一覧の行の題の横に出す）。何も無ければ何も出さない
struct ReflectionBadge: View {
    let targets: [IntentTarget]

    @Environment(ClientStore.self) private var store

    init(_ targets: [IntentTarget]) {
        self.targets = targets
    }

    var body: some View {
        if let reflection = store.reflection(for: targets) {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                let message = ReflectionMessage.make(
                    reflection,
                    now: store.currentDate(),
                    stallThreshold: store.stallThreshold,
                    commanderSeenAt: store.snapshot?.commanderSeenAt
                )
                HStack(spacing: 4) {
                    ReflectionSymbol(tone: message.tone)
                        .controlSize(.mini)
                    Text(message.badge)
                        .appFont(.caption2, weight: .semibold)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(message.tone.tint)
                .background(message.tone.tint.opacity(0.14), in: .capsule)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reflection-badge")
            }
        }
    }
}

/// 様子の印。反映を待っている間は回る印、受け取りが遅いときは注意、断られたときは赤
private struct ReflectionSymbol: View {
    let tone: ReflectionMessage.Tone

    var body: some View {
        switch tone {
        case .progress:
            ProgressView()
                .controlSize(.small)

        case .stalled:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)

        case .rejected:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Theme.danger)
        }
    }
}

private extension ReflectionMessage.Tone {
    var tint: Color {
        switch self {
        case .progress: Theme.accent
        case .stalled: Theme.warning
        case .rejected: Theme.danger
        }
    }

    var titleStyle: AnyShapeStyle {
        switch self {
        case .progress: AnyShapeStyle(.primary)
        case .stalled: AnyShapeStyle(Theme.warning)
        case .rejected: AnyShapeStyle(Theme.danger)
        }
    }
}
