import SwiftUI

/// 判断のカードの中身（札の表）。上にアプリの色の帯を置き、どのアプリの判断かを一目で分かるようにする
struct DeckCardContent: View {
    let card: DeckCard
    let repository: TargetRepository?
    let epic: Epic?
    let directions: [SwipeDirection]
    let drag: SwipeDragState
    /// 残りの枚数（一番上のカードにだけ出す）
    var remaining: Int?
    let commit: (Int) -> Void
    let onSubmitText: (String) -> Void

    @State private var freeText = ""
    @FocusState private var isWriting: Bool

    var body: some View {
        // 上に何を決めるか、下（親指に近い側）に選択肢を置く
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                DeckCardHeader(repository: repository, epicTitle: epic?.title ?? "", remaining: remaining)
                summary
                    .padding([.horizontal, .top], 16)
                Spacer(minLength: 12)
            }
            // 自由記述のカードは、入力欄より上を叩くとキーボードを閉じる。
            // スワイプで選ばないカードなので、スワイプの操作とはぶつからない
            .contentShape(.rect)
            .gesture(TapGesture().onEnded { isWriting = false }, isEnabled: Self.closesKeyboardOnTap && card.choices.isEmpty)
            Group {
                if card.choices.isEmpty {
                    freeTextField
                } else {
                    choices
                }
            }
            .padding([.horizontal, .bottom], 16)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.kindLabel)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text(card.title)
                    .appFont(.title3, weight: .semibold)
                    .lineLimit(3)
                Text(card.detail)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            contextNotes
            if case .decision(let decision) = card.content, decision.before != nil || decision.after != nil {
                BeforeAfterView(before: decision.before, after: decision.after)
                    .frame(maxHeight: 150)
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
                .accessibilityLabel(Self.accessibilityLabel(of: choice, direction: directions[index]))
                .accessibilityHint(choice.detail)
            }
        }
    }

    /// 選択肢の読み上げ。札（推奨・自由回答）も方向と一緒に読む（例: 直してほしい（自由回答・左下へスワイプ））
    static func accessibilityLabel(of choice: DeckCard.Choice, direction: SwipeDirection) -> String {
        let badges = [choice.isRecommended ? "推奨" : nil, choice.asksText ? "自由回答" : nil].compactMap(\.self)
        let parts = badges + ["\(direction.accessibilityName)へスワイプ"]
        return "\(choice.label)（\(parts.joined(separator: "・"))）"
    }

    private var freeTextField: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("回答を書く", text: $freeText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($isWriting)
                .accessibilityIdentifier("deckCard.freeText")
            Button("回答する") {
                isWriting = false
                onSubmitText(freeText)
            }
            .buttonStyle(.glassProminent)
            .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .keepsControlSize()
        // デッキには自由記述のカードが重なることがあるので、入力中のカードの分だけ「完了」を出す
        .keyboardDoneButton($isWriting, onlyWhileFocused: true)
    }

    @ViewBuilder private var contextNotes: some View {
        switch card.content {
        case .question(let question):
            QuestionNotes(question: question, epic: epic)

        case .decision(let decision):
            VStack(alignment: .leading, spacing: 6) {
                if case .delegated(let questionID) = decision.kind {
                    TagLabel(text: "おまかせ（\(questionID)）", tint: Theme.accent)
                } else {
                    TagLabel(text: "見える仮決め", tint: .secondary)
                }
                if case .refreshed(let note) = decision.response {
                    TagLabel(text: note, tint: Theme.warning)
                }
            }

        case .verification:
            EmptyView()
        }
    }

    #if os(macOS)
    private static let showsKeyHints = true
    /// Mac にはソフトウェアキーボードが無いので、カードを叩いても入力欄のフォーカスは外さない
    private static let closesKeyboardOnTap = false
    #else
    private static let showsKeyHints = false
    private static let closesKeyboardOnTap = true
    #endif
}

/// 札の上の帯。アプリの色のグラデーションに、アイコン・アプリ名・epic・残りの枚数を載せる
struct DeckCardHeader: View {
    let repository: TargetRepository?
    let epicTitle: String
    let remaining: Int?

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(repository: repository, size: 38)
                .overlay(RoundedRectangle(cornerRadius: 38 * 0.225, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(repository?.appName ?? "不明なリポジトリ")
                    .appFont(.subheadline, weight: .bold)
                Text(epicTitle)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let remaining {
                Text("残り \(remaining)")
                    .appFont(.caption, weight: .semibold)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.background.opacity(0.7), in: .capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if case let .symbol(_, tint) = repository?.icon {
            return tint.color
        }
        return Theme.accent
    }
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
                    .appFont(.caption)
                    .foregroundStyle(.tint)
            }
            if let note = question.revisionNote {
                Label(note, systemImage: "pencil.and.list.clipboard")
                    .appFont(.caption)
                    .foregroundStyle(Theme.warning)
            }
            if let explanation = question.latestExplanation, let body = explanation.body {
                VStack(alignment: .leading, spacing: 4) {
                    Label("説明が届いています", systemImage: "text.bubble")
                        .appFont(.caption, weight: .semibold)
                    Text(body)
                        .appFont(.caption)
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
