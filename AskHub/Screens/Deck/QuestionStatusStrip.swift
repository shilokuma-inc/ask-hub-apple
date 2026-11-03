import SwiftUI

/// epic の質問ごとの状態（回答済み・未回答・説明待ち・ロック）を横に並べた帯
struct QuestionStatusStrip: View {
    let epic: Epic

    var body: some View {
        HStack(spacing: 6) {
            ForEach(epic.questions) { question in
                VStack(spacing: 3) {
                    Image(systemName: question.statusSymbol)
                        .appFont(.footnote)
                        .foregroundStyle(question.statusColor)
                    Text(question.id)
                        .appFont(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 30)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(question.id) \(question.statusLabel)")
            }
        }
    }
}

extension Question {
    var statusSymbol: String {
        switch state {
        case .open: "circle"
        case .awaitingExplanation: "text.bubble"
        case .locked: "lock.fill"
        case .reviewing: "arrow.triangle.2.circlepath"
        case .answered: "checkmark.circle.fill"
        case .delegated: "wand.and.sparkles"
        }
    }

    var statusColor: Color {
        switch state {
        case .open: Theme.accent
        case .awaitingExplanation: Theme.warning
        case .locked, .reviewing: .secondary
        case .answered: Theme.success
        case .delegated: Theme.Tone.lavender
        }
    }

    var statusLabel: String {
        switch state {
        case .open: "未回答"
        case .awaitingExplanation: "説明待ち"
        case .locked: "ロック"
        case .reviewing: "見直し中"
        case .answered: "回答済み"
        case .delegated: "おまかせ"
        }
    }
}
