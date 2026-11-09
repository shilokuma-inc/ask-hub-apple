import SwiftUI

/// 送った意図について知らせることを、操作した場所（カード・行・ボタンの下）に出す 1 行。
///
/// 画面は押した時点で送った結果の形になるので、出すのは司令塔がしばらく受け取っていない・断った（理由と閉じるボタン）ときだけ。
/// 同期を待っているだけなら何も出さない（`showsSyncBadge` なら小さな「同期待ち」の印だけを出す）。
/// 全画面のローディングにはせず、ほかの対象や画面は普段どおり使えるようにする。iOS と macOS で同じ View を使う
struct ReflectionStatusView: View {
    let targets: [IntentTarget]
    /// 一覧の外（山札の上など）に置くときに、ガラスの地に載せる
    var framed = false
    /// 同期を待っている間、小さな印（`ReflectionBadge`）を出す
    var showsSyncBadge = false

    @Environment(ClientStore.self) private var store

    init(_ targets: [IntentTarget], framed: Bool = false, showsSyncBadge: Bool = false) {
        self.targets = targets
        self.framed = framed
        self.showsSyncBadge = showsSyncBadge
    }

    init(_ target: IntentTarget, framed: Bool = false, showsSyncBadge: Bool = false) {
        self.init([target], framed: framed, showsSyncBadge: showsSyncBadge)
    }

    var body: some View {
        if let reflection = store.reflection(for: targets) {
            if store.needsAttention(targets) {
                // 司令塔が受け取らないまま時間がたったことを、読み直しを待たずに出す
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    content(message(reflection))
                }
            } else if showsSyncBadge {
                ReflectionBadge(targets, syncOnly: true)
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

    @ViewBuilder private func content(_ message: ReflectionMessage) -> some View {
        if framed {
            line(message)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 520)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            line(message)
        }
    }

    private func line(_ message: ReflectionMessage) -> some View {
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

/// 送った意図が反映されるまでの様子の小さな印（一覧の行の題の横・カードの隅に出す）。
/// 同期を待つ間は「同期待ち」、司令塔がしばらく受け取っていなければ「受け取り待ち」、断られたら「受け付けられず」。何も無ければ何も出さない
struct ReflectionBadge: View {
    private enum Subject {
        case targets([IntentTarget])
        /// epic への操作のどれか
        case epic(Epic.ID)
    }

    private let subject: Subject
    /// 同期を待っている間だけ出す（受け取りの遅れ・断られた理由は、同じ場所の `ReflectionStatusView` が出す）
    private let syncOnly: Bool

    @Environment(ClientStore.self) private var store

    init(_ targets: [IntentTarget], syncOnly: Bool = false) {
        subject = .targets(targets)
        self.syncOnly = syncOnly
    }

    /// epic への操作（質問・判断・ゴール・epic の操作など）のどれかの様子
    init(epicID: Epic.ID) {
        subject = .epic(epicID)
        syncOnly = false
    }

    private var reflection: Reflection? {
        let reflection = switch subject {
        case .targets(let targets): store.reflection(for: targets)
        case .epic(let epicID): store.reflection(forEpic: epicID)
        }
        guard let reflection, syncOnly else {
            return reflection
        }
        let needsAttention = reflection.needsAttention(now: store.currentDate(), threshold: store.stallThreshold)
        return reflection.isPending && !needsAttention ? reflection : nil
    }

    var body: some View {
        if let reflection {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                let message = ReflectionMessage.make(
                    reflection,
                    now: store.currentDate(),
                    stallThreshold: store.stallThreshold,
                    commanderSeenAt: store.snapshot?.commanderSeenAt
                )
                HStack(spacing: 3) {
                    ReflectionSymbol(tone: message.tone)
                        .imageScale(.small)
                    Text(message.badge)
                }
                .appFont(.caption2, weight: .semibold)
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

/// 様子の印。同期を待っている間は同期の矢印（動かさない。待たせる表示にしない）、受け取りが遅いときは注意、断られたときは赤
private struct ReflectionSymbol: View {
    let tone: ReflectionMessage.Tone

    var body: some View {
        switch tone {
        case .progress:
            Image(systemName: "arrow.triangle.2.circlepath")

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
