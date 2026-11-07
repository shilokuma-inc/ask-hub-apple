import SwiftUI

/// 質問の全文と、開始の前の回答の直し
struct QuestionSheet: View {
    let epic: Epic
    let question: Question

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @FocusState private var isEditingNote: Bool

    /// 回答を変えられるのは開始の前まで。やめた epic の質問には答えない
    private var canChangeAnswer: Bool {
        let current = store.epic(epic.id) ?? epic
        return current.isActive && current.stage <= .goal && (question.isSettled || question.isAnswerable)
    }

    var body: some View {
        NavigationStack {
            List {
                QuestionDetailSections(question: question, epic: store.epic(epic.id))
                if canChangeAnswer {
                    answerSection
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(question.id)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .keyboardDoneButton($isEditingNote)
        }
    }

    private var answerSection: some View {
        CardSection {
            ForEach(question.options) { option in
                Button {
                    send(.answer(epicID: epic.id, questionID: question.id, optionID: option.id, note: note))
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        if question.answeredOption?.id == option.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            TextField(question.isFreeText ? "回答" : "補足（任意）", text: $note, axis: .vertical)
                .focused($isEditingNote)
            if question.isFreeText {
                Button("この内容で回答する") {
                    send(.answer(epicID: epic.id, questionID: question.id, optionID: nil, note: note))
                }
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text(question.isSettled ? "回答を直す" : "回答する")
        } footer: {
            let dependents = epic.questions.dependents(of: question)
            if question.isSettled, !dependents.isEmpty {
                Text("直すと、\(dependents.map(\.id).joined(separator: "・")) の回答を取り消して見直しからやり直します")
            } else {
                Text("開始の前なら、回答はあとから直せます")
            }
        }
    }

    private func send(_ intent: HumanIntent) {
        Task {
            await store.send(intent)
            dismiss()
        }
    }
}
