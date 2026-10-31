import AskHubKit
import SwiftUI

/// 質問の詳細と回答の入力
struct QuestionDetailView: View {
    let inbox: InboxModel
    /// 本文のブロック要素。変換は描画のたびに走らせず、画面を作るときに 1 回だけ行う
    private let renderedBody: RenderedBody
    @State private var form: AnswerFormModel
    @State private var isConfirmingLoopStart = false
    /// 投稿の前とキーボードの「完了」でキーボードを閉じ、確認や結果・ボタンが隠れないようにする
    @FocusState private var isEditingNote: Bool
    @Environment(\.dismiss)
    private var dismiss

    init(question: InboxQuestion, inbox: InboxModel) {
        self.inbox = inbox
        renderedBody = RenderedBody(body: question.questionBody)
        _form = State(initialValue: AnswerFormModel(question: question, inbox: inbox))
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
                RenderedBodyView(content: renderedBody)
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

            if !form.isPosted {
                // 添付は回答の返信の末尾に添付欄として付く。投稿中は一覧を変えさせない
                AttachmentPickerSection(attachments: $form.attachments, notices: $form.attachmentNotices, isDisabled: form.isPosting)
            }

            if question.subject.kind == .discussion && !form.isPosted {
                loopSection
            }

            if let errorMessage = form.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if form.loopStartFailed {
                        Button((form.postedRunner ?? form.loopRunner) == .manual ? "manual-loop を付ける（再試行）" : "ループを始める（再試行）") {
                            Task {
                                await form.startLoop(using: inbox)
                                // 手で回すなら、指示を見せるため閉じない
                                if !form.loopStartFailed && form.manualLoopInstruction == nil {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(form.isPosting)
                    }
                }
            }

            if let instruction = form.manualLoopInstruction {
                ManualLoopInstructionSection(
                    instruction: instruction,
                    assignee: form.isAssignedToViewer ? nil : form.postedAssignee
                ) { dismiss() }
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
                            Text(postButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!form.canPost)
                }
            }
        }
        // ループの起動は取り消せず、トークンも消費するので、確かめてから始める。手で回すときも、オーケストレーターがこの Discussion を起動しなくなるので確かめる
        .confirmationDialog(
            form.loopRunner == .manual ? "回答を投稿して、手動で回しますか？" : "回答を投稿して、ループを始めますか？",
            isPresented: $isConfirmingLoopStart,
            titleVisibility: .visible
        ) {
            Button(form.loopRunner == .manual ? "投稿して手動で回す" : "投稿してループを始める") { post() }
        } message: {
            Text(loopStartConfirmation)
        }
        .formStyle(.grouped)
        .keyboardDoneButton($isEditingNote)
        .navigationTitle(question.subject.shortReference)
    }

    /// Discussion の回答を確定してループを始める（Discussion #1 の Q3）
    @ViewBuilder private var loopSection: some View {
        let remaining = inbox.remainingQuestions(besides: question)
        Section {
            if form.canStartLoop(in: inbox) {
                Toggle("投稿したら、回答を確定してループを始める", isOn: $form.startsLoopAfterPosting)
                    .disabled(form.isPosting)
                // 信用外の author の Discussion に付いた manual-loop はオーケストレーターが無視するので、選ばせない
                if form.startsLoopAfterPosting && form.canRunManually(in: inbox) {
                    Picker("回し方", selection: $form.loopRunner) {
                        ForEach(LoopRunner.allCases, id: \.self) { runner in
                            Text(runner.title).tag(runner)
                        }
                    }
                    .disabled(form.isPosting)
                    if form.loopRunner == .manual {
                        Picker("担当者", selection: $form.assignee) {
                            if form.assigneeCandidates.isEmpty {
                                Text("読み込み中…").tag(String?.none)
                            }
                            ForEach(form.assigneeCandidates, id: \.self) { login in
                                Text(login == form.viewerLogin ? "@\(login)（自分）" : "@\(login)").tag(Optional(login))
                            }
                        }
                        .disabled(form.isPosting)
                        .accessibilityIdentifier("manual-loop-assignee")
                        .task { await form.loadAssignees(using: inbox) }
                    }
                }
                // モデルとエフォートはオーケストレーターの自動ループにだけ効くので、手で回すときは出さない
                if form.startsLoopAfterPosting && form.loopRunner == .orchestrator {
                    loopOptionPickers
                }
            } else {
                Text("この Discussion には、ほかに未回答の質問が \(remaining) 件あります")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ループ")
        } footer: {
            Text(loopFooter)
        }
    }

    /// 自動ループのモデルとエフォート。既定は担当 PC の設定（orchestrator.json の model / effort）。
    /// 担当 PC の設定はアプリから見えないので、既定の選択肢にモデル名は出さない
    @ViewBuilder private var loopOptionPickers: some View {
        Picker("モデル", selection: $form.loopModel) {
            Text("担当 PC の既定").tag(LoopModel?.none)
            ForEach(LoopModel.allCases, id: \.self) { model in
                Text(model.title).tag(Optional(model))
            }
        }
        .disabled(form.isPosting)
        .accessibilityIdentifier("loop-model")
        Picker("エフォート", selection: $form.loopEffort) {
            Text("担当 PC の既定").tag(LoopEffort?.none)
            ForEach(LoopEffort.allCases, id: \.self) { effort in
                Text(effort.title).tag(Optional(effort))
            }
        }
        .disabled(form.isPosting)
        .accessibilityIdentifier("loop-effort")
    }

    private var loopFooter: String {
        guard form.canStartLoop(in: inbox) else {
            return "すべての質問に答えると、回答を確定してループを始められます"
        }
        guard form.startsLoopAfterPosting else {
            return "回答だけを投稿します。オンにすると、回答を確定してループを始められます"
        }
        if form.loopRunner == .manual {
            return "Discussion に manual-loop を付け、担当者を @メンションで知らせます。オーケストレーターはこの Discussion のループを起動しません（このリポジトリのほかの自動ループは止めません）。"
                + "担当者が自分の Mac の Claude Code でループを回します（指示はステータスタブの「手動ループ」からもコピーできます）"
        }
        let options = form.loopOptions.isDefault
            ? ""
            : "先にモデルとエフォート（\(form.loopOptions.summary)）をコメントで残し、準備・ループ・再開で使わせます。"
        return "Discussion に ready-for-loop を付けます。担当 PC のオーケストレーターがループを起動します。" + options
    }

    private var postButtonTitle: String {
        guard form.startsLoopAfterPosting else {
            return "回答を投稿"
        }
        return form.loopRunner == .manual ? "回答を投稿して手動で回す" : "回答を投稿してループを始める"
    }

    private var loopStartConfirmation: String {
        let discussion = "\(question.subject.shortReference)「\(question.subject.title)」"
        return form.loopRunner == .manual
            ? "\(discussion)に manual-loop を付けます。オーケストレーターはこの Discussion のループを起動しません（このリポジトリのほかの自動ループは止めません）"
            : "\(discussion)に ready-for-loop を付け、担当 PC のオーケストレーターが \(form.loopOptions.summary) でループを起動します"
    }

    private func post() {
        Task {
            await form.post(using: inbox)
            // ループを始めなかった理由（errorMessage）や、手で回すときの指示があるときは、閉じずに見せる
            if form.isPosted && !form.loopStartFailed && form.errorMessage == nil && form.manualLoopInstruction == nil {
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

#if DEBUG
#Preview("選択肢あり") {
    NavigationStack {
        QuestionDetailView(question: SampleInboxSource.sampleQuestion, inbox: .sample())
    }
}
#endif
