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
                        .font(.title3)
                    Text(step.title)
                        .font(.caption2)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if index == current {
            Image(systemName: isBlocked ? "exclamationmark.circle.fill" : "circle.circle.fill")
                .foregroundStyle(isBlocked ? Color.red : Color.accentColor)
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
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

/// 「あなたの番」の種類の印（アプリのアイコンの右下に重ねる）
struct InboxKindBadge: View {
    let kind: InboxItem.Kind
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
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
        case .questions: .blue
        case .goal: .indigo
        case .humanTask: .orange
        case .blocker: .red
        case .macOffline: .gray
        case .finalReview: .purple
        case .verification: .teal
        case .cleanup: .brown
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
