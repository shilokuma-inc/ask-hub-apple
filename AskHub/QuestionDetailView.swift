import AskHubKit
import SwiftUI

/// 質問の詳細と回答の入力
struct QuestionDetailView: View {
    let inbox: InboxModel
    @State private var form: AnswerFormModel
    @Environment(\.dismiss)
    private var dismiss

    init(question: InboxQuestion, inbox: InboxModel) {
        self.inbox = inbox
        _form = State(initialValue: AnswerFormModel(question: question))
    }

    private var question: InboxQuestion {
        form.question
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(question.subject.kind == .discussion ? "Discussion" : "Pull Request", value: question.subject.shortReference)
                Text(question.subject.title)
                Link("GitHub で開く", destination: question.comment.url)
            }

            Section("質問") {
                Text(question.detailText)
                    .textSelection(.enabled)
            }

            if !question.marker.isFreeForm {
                Section("選択肢") {
                    ForEach(question.marker.options, id: \.self) { option in
                        optionButton(option)
                    }
                }
            }

            Section {
                TextField(question.marker.isFreeForm ? "回答" : "補足（任意）", text: $form.note, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text(question.marker.isFreeForm ? "回答" : "補足")
            } footer: {
                Text(question.marker.isFreeForm ? "入力した内容を返信として投稿します" : "「回答: 選択肢」の次の行に続けて投稿します")
            }

            if let errorMessage = form.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        await form.post(using: inbox)
                        if form.isPosted {
                            dismiss()
                        }
                    }
                } label: {
                    if form.isPosting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("回答を投稿")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!form.canPost)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(question.subject.shortReference)
    }

    private func optionButton(_ option: String) -> some View {
        Button {
            form.choice = option
        } label: {
            HStack {
                Text(option)
                    .foregroundStyle(.primary)
                Spacer()
                if form.choice == option {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(form.choice == option ? .isSelected : [])
    }
}

extension InboxQuestion {
    /// 詳細に出す質問の本文。Markdown の画像（`ask-badge` など）と見出しの `#` を除き、改行は残す
    var detailText: AttributedString {
        let text = questionBody
            .replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 太字やコードなどのインラインの装飾だけを解釈する
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#if DEBUG
#Preview("選択肢あり") {
    NavigationStack {
        QuestionDetailView(question: SampleInboxSource.sampleQuestion, inbox: .sample())
    }
}
#endif
