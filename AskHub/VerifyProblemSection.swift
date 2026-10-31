import AskHubKit
import SwiftUI

/// 実機確認の詳細画面の「問題あり」。問題の内容を書かせ、確かめてから再修正の依頼と実機確認 Issue へのコメントを送る（Issue #483）
struct VerifyProblemSection: View {
    @Bindable var model: VerifyProblemModel
    var isEditing: FocusState<Bool>.Binding
    @State private var isConfirming = false

    var body: some View {
        Section {
            if let request = model.createdRequest, model.isCompleted {
                Label("再修正の依頼 #\(request.number) を作り、この Issue にコメントしました", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Link("依頼を GitHub で開く", destination: request.htmlURL)
            } else {
                TextField("何をしたら・どうなったか", text: $model.description, axis: .vertical)
                    .lineLimit(3...8)
                    .focused(isEditing)
                    // 依頼を作った後は、コメントを依頼の本文とそろえるため変えさせない
                    .disabled(model.isSending || model.createdRequest != nil)
            }
        } header: {
            Text("問題あり")
        }

        if !model.isCompleted {
            // 添付は依頼の本文とコメントの両方の末尾に付く。依頼を作った後は変えさせない（コメントの再試行で上げ直さない）
            AttachmentPickerSection(
                attachments: $model.attachments,
                notices: $model.attachmentNotices,
                isDisabled: model.isSending || model.createdRequest != nil
            )
            sendSection
        }
    }

    private var sendSection: some View {
        Section {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button {
                isEditing.wrappedValue = false
                isConfirming = true
            } label: {
                if model.isSending {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(model.isRetryingComment ? "コメントだけを再送する" : "問題ありとして再修正を依頼する")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!model.canSend)
            // 依頼とコメントは GitHub に書き込むので、送る内容を見せて確かめる
            .confirmationDialog(
                model.isRetryingComment ? "コメントだけを再送しますか？" : "再修正を依頼しますか？",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button(model.isRetryingComment ? "再送する" : "依頼する") {
                    Task { await model.send() }
                }
            } message: {
                Text(model.confirmation)
            }
        } footer: {
            Text("確認手順のとおりにならなかったら、同じリポジトリに再修正の依頼を作り、この Issue に問題の内容をコメントします。Issue は閉じません。再修正の後にもう一度確かめてください")
        }
    }
}
