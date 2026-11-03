import SwiftUI

/// 判断のカードの中身。どのアプリの判断かを、アイコンと名前で一番上に出す
struct DeckCardContent: View {
    let card: DeckCard
    let repository: TargetRepository?
    let epic: Epic?
    let directions: [SwipeDirection]
    let drag: SwipeDragState
    let commit: (Int) -> Void
    let onSubmitText: (String) -> Void

    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppHeaderView(repository: repository, subtitle: epic?.title ?? "")
            VStack(alignment: .leading, spacing: 4) {
                Text(card.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(card.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Text(card.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            contextNotes
            if case .decision(let decision) = card.content, decision.before != nil || decision.after != nil {
                BeforeAfterView(before: decision.before, after: decision.after)
                    .frame(maxHeight: 150)
            }
            if card.choices.isEmpty {
                freeTextField
            } else {
                choices
            }
        }
    }

    private var choices: some View {
        VStack(spacing: 6) {
            ForEach(Array(card.choices.enumerated()), id: \.element.id) { index, choice in
                Button {
                    commit(index)
                } label: {
                    SwipeChoiceRow(
                        choice: choice,
                        direction: directions[index],
                        index: index,
                        drag: drag,
                        keyHint: Self.showsKeyHints ? "\(index + 1)" : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(choice.label)（\(directions[index].accessibilityName)へスワイプ）")
                .accessibilityHint(choice.detail)
            }
        }
    }

    private var freeTextField: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("回答を書く", text: $freeText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            Button("回答する") { onSubmitText(freeText) }
                .buttonStyle(.glassProminent)
                .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private var contextNotes: some View {
        switch card.content {
        case .question(let question):
            QuestionNotes(question: question, epic: epic)

        case .decision(let decision):
            VStack(alignment: .leading, spacing: 6) {
                if case .delegated(let questionID) = decision.kind {
                    TagLabel(text: "おまかせ（\(questionID)）", tint: .purple)
                } else {
                    TagLabel(text: "見える仮決め", tint: .secondary)
                }
                if case .refreshed(let note) = decision.response {
                    TagLabel(text: note, tint: .orange)
                }
            }

        case .verification:
            EmptyView()
        }
    }

    #if os(macOS)
    private static let showsKeyHints = true
    #else
    private static let showsKeyHints = false
    #endif
}

/// 質問のカードの補足（依存される質問・見直した点・届いた説明）
struct QuestionNotes: View {
    let question: Question
    let epic: Epic?

    var body: some View {
        let dependents = epic?.questions.dependents(of: question) ?? []
        VStack(alignment: .leading, spacing: 6) {
            if !dependents.isEmpty {
                Label("この回答で \(dependents.map(\.id).joined(separator: "・")) が決まります", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if let note = question.revisionNote {
                Label(note, systemImage: "pencil.and.list.clipboard")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let explanation = question.latestExplanation, let body = explanation.body {
                VStack(alignment: .leading, spacing: 4) {
                    Label("説明が届いています", systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
