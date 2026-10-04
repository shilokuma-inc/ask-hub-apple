import AskHubKit
import SwiftUI

/// 質問の詳細と回答の入力
struct QuestionDetailView: View {
    let inbox: InboxModel
    @State private var form: AnswerFormModel
    @State private var isConfirmingLoopStart = false
    /// 投稿の前にキーボードを閉じ、確認や結果が隠れないようにする
    @FocusState private var isEditingNote: Bool
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
                    .focused($isEditingNote)
            } header: {
                Text(question.marker.isFreeForm ? "回答" : "補足")
            } footer: {
                Text(question.marker.isFreeForm ? "入力した内容を返信として投稿します" : "「回答: 選択肢」の次の行に続けて投稿します")
            }

            if question.subject.kind == .discussion && !form.isPosted {
                loopSection
            }

            if let errorMessage = form.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if form.loopStartFailed {
                        Button("ループを始める（再試行）") {
                            Task {
                                await form.startLoop(using: inbox)
                                if !form.loopStartFailed {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(form.isPosting)
                    }
                }
            }

            if !form.isPosted {
                Section {
                    if !question.marker.isFreeForm {
                        // 投稿前に、GitHub に書かれる 1 行目を確かめられるようにする（Discussion #142 の Q3）
                        if let choiceLine = form.answer.choiceLine {
                            Text(choiceLine)
                        } else {
                            Text("選択肢を選んでください")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        isEditingNote = false
                        if form.startsLoopAfterPosting {
                            isConfirmingLoopStart = true
                        } else {
                            post()
                        }
                    } label: {
                        if form.isPosting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(form.startsLoopAfterPosting ? "回答を投稿してループを始める" : "回答を投稿")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!form.canPost)
                }
            }
        }
        // ループの起動は取り消せず、トークンも消費するので、確かめてから始める
        .confirmationDialog(
            "回答を投稿して、ループを始めますか？",
            isPresented: $isConfirmingLoopStart,
            titleVisibility: .visible
        ) {
            Button("投稿してループを始める") { post() }
        } message: {
            Text("\(question.subject.shortReference)「\(question.subject.title)」に ready-for-loop を付け、担当 PC のオーケストレーターがループを起動します")
        }
        .formStyle(.grouped)
        .navigationTitle(question.subject.shortReference)
    }

    /// Discussion の回答を確定してループを始める（Discussion #1 の Q3）
    @ViewBuilder private var loopSection: some View {
        let remaining = inbox.remainingQuestions(besides: question)
        Section {
            if form.canStartLoop(in: inbox) {
                Toggle("投稿したら、回答を確定してループを始める", isOn: $form.startsLoopAfterPosting)
            } else {
                Text("この Discussion には、ほかに未回答の質問が \(remaining) 件あります")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ループ")
        } footer: {
            Text(form.canStartLoop(in: inbox)
                ? "Discussion に ready-for-loop を付けます。担当 PC のオーケストレーターがループを起動します"
                : "すべての質問に答えると、回答を確定してループを始められます")
        }
    }

    private func post() {
        Task {
            await form.post(using: inbox)
            // ループを始めなかった理由（errorMessage）があるときは、閉じずに見せる
            if form.isPosted && !form.loopStartFailed && form.errorMessage == nil {
                dismiss()
            }
        }
    }

    /// 選んだ選択肢は、印を出さずに行の背景と太字・アクセントカラーで示す（Discussion #142 の Q1・Q2）
    private func optionButton(_ option: String) -> some View {
        let isSelected = form.choice == option
        return Button {
            form.choice = option
        } label: {
            // 常に太字の幅で高さを確保し、選んだ瞬間に行の高さが変わらないようにする
            ZStack(alignment: .topLeading) {
                Text(option)
                    .bold()
                    .hidden()
                    .accessibilityHidden(true)
                Text(option)
                    .bold(isSelected)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
