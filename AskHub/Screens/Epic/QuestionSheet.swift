import SwiftUI

/// 質問の全文と、開始の前の回答の直し
struct QuestionSheet: View {
    let epic: Epic
    let question: Question

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var sending = SheetSendState()
    /// 最後に送ろうとした回答（失敗したとき、もう一度送る）
    @State private var lastIntent: HumanIntent?
    @FocusState private var isEditingNote: Bool

    private var target: IntentTarget {
        .question(epicID: epic.id, questionID: question.id)
    }

    /// 回答を変えられるのは開始の前まで。開始した後は、答えを待っている実装の途中の質問にだけ答える（答えたら再開するので、答え直せない）。
    /// やめた epic の質問には答えない
    private var canChangeAnswer: Bool {
        let current = store.epic(epic.id) ?? epic
        guard current.stage <= .goal else {
            return current.awaitedQuestions.contains { $0.id == question.id }
        }
        return current.isActive && (question.isSettled || question.isAnswerable)
    }

    var body: some View {
        NavigationStack {
            List {
                if sending.showsStatus {
                    CardSection {
                        SheetSendStatus(state: sending) {
                            if let lastIntent {
                                send(lastIntent)
                            }
                        }
                    }
                } else if store.reflection(for: [target]) != nil {
                    // 前に送った回答が反映を待っているか、断られた。反映されるまでは答え直せない
                    CardSection {
                        ReflectionStatusView(target)
                    }
                }
                QuestionDetailSections(question: question, epic: store.epic(epic.id))
                if canChangeAnswer {
                    answerSection
                        .disabled(sending.isSending || store.isReflecting([target]))
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
                        .disabled(sending.isSending)
                }
            }
            .keyboardDoneButton($isEditingNote)
        }
        .sheetSending(sending)
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

    /// 送る。置けたら（同じ回答を送ってあったときも）閉じ、失敗したら理由を出して残る
    private func send(_ intent: HumanIntent) {
        guard !sending.isSending else {
            return
        }
        lastIntent = intent
        isEditingNote = false
        Task {
            if case .failed = await sending.send(intent, in: store) {
                return
            }
            dismiss()
        }
    }
}
