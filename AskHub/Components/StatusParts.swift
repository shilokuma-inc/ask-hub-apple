import SwiftUI

/// epic の段階の帯（依頼・質問・確認・実装・最終 PR・完了）
struct StageTrackerView: View {
    let stage: Epic.Stage
    /// いまの段階が人に渡された失敗で止まっているか
    var isBlocked = false

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let stages: [Epic.Stage]
    }

    private static let steps = [
        Step(id: 0, title: "依頼", stages: [.request]),
        Step(id: 1, title: "質問", stages: [.questions]),
        Step(id: 2, title: "確認", stages: [.preflight, .goal]),
        Step(id: 3, title: "実装", stages: [.implementing]),
        Step(id: 4, title: "最終 PR", stages: [.finalReview]),
        Step(id: 5, title: "完了", stages: [.done])
    ]

    var body: some View {
        let current = Self.steps.first { $0.stages.contains(stage) }?.id ?? 0
        HStack(spacing: 0) {
            ForEach(Self.steps) { step in
                VStack(spacing: 4) {
                    symbol(for: step.id, current: current)
                        .appFont(.title3)
                    Text(step.title)
                        .appFont(.caption2)
                        .foregroundStyle(step.id == current ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("段階: \(Self.steps[current].title)\(isBlocked ? "（止まっています）" : "")")
    }

    @ViewBuilder private func symbol(for index: Int, current: Int) -> some View {
        if index < current || stage == .done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        } else if index == current {
            Image(systemName: isBlocked ? "exclamationmark.circle.fill" : "circle.circle.fill")
                .foregroundStyle(isBlocked ? Theme.danger : Theme.accent)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// 小さなラベル（推奨・区分 など）
struct TagLabel: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .appFont(.caption2, weight: .semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

/// 「あなたの番」の種類の印（アプリのアイコンの右下に重ねる）
struct InboxKindBadge: View {
    let kind: InboxItem.Kind
    /// テキストサイズが標準のときの大きさ。設定に合わせて伸び縮みする（ContentScale）
    var size: CGFloat = 18

    @ContentScale private var scale

    var body: some View {
        let side = size * scale
        Image(systemName: kind.systemImage)
            .font(.system(size: side * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(kind.tint, in: .circle)
            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

extension InboxItem.Kind {
    var systemImage: String {
        switch self {
        case .questions: "questionmark"
        case .goal: "flag.fill"
        case .humanTask: "wrench.fill"
        case .blocker: "exclamationmark"
        case .macOffline: "wifi.slash"
        case .finalReview: "arrow.triangle.merge"
        case .verification: "iphone"
        case .cleanup: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .questions: Theme.Tone.sky
        case .goal: Theme.Tone.lavender
        case .humanTask: Theme.Tone.peach
        case .blocker: Theme.Tone.rose
        case .macOffline: Theme.Tone.slate
        case .finalReview: Theme.Tone.lavender
        case .verification: Theme.Tone.aqua
        case .cleanup: Theme.Tone.butter
        }
    }
}

#Preview("段階の帯") {
    VStack(spacing: 24) {
        StageTrackerView(stage: .questions)
        StageTrackerView(stage: .implementing, isBlocked: true)
        StageTrackerView(stage: .done)
    }
    .padding()
}
