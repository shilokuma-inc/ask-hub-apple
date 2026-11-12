import AskHubKit
import SwiftUI

/// 依頼の下書き（分け方の案から依頼し直すとき）
struct RequestDraft: Identifiable, Hashable {
    var id: String { summary }
    var repositoryID: TargetRepository.ID
    var summary: String
    var body: String
}

/// 新しい依頼。依頼先には対象のリポジトリだけを、organization ごとに分けて出す。添付は、意図より先に状態リポジトリに置く。
///
/// 送っている間は触れなくし、置けたら送った依頼（司令塔が受け取る前の epic）へ移る。同じ下書きのまま、もう一度送れる状態に残さない
struct NewRequestSheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryID: TargetRepository.ID?
    @State private var summary: String
    @State private var requestBody: String
    @State private var attachments: [AttachmentFile] = []
    /// 選んだのに足さなかったファイル・送れなかったファイルの説明
    @State private var attachmentNotices: [String] = []
    @State private var sending = SheetSendState()
    /// 同じ内容の依頼を少し前に送った時刻（重ねて送るかを確かめる）
    @State private var duplicateSentAt: Date?
    @FocusState private var isEditing: Bool

    init(draft: RequestDraft? = nil) {
        _repositoryID = State(initialValue: draft?.repositoryID)
        _summary = State(initialValue: draft?.summary ?? "")
        _requestBody = State(initialValue: draft?.body ?? "")
    }

    private var canSend: Bool {
        repositoryID != nil && !summary.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 送る意図。添付のハッシュを計るので、描くたびではなく送るときに作る。送れない添付があれば、説明を添付欄に出して nil
    private func makeIntent() -> HumanIntent? {
        guard let repositoryID, canSend else {
            return nil
        }
        switch RequestFile.make(attachments) {
        case let .success(files):
            return .request(repositoryID: repositoryID, summary: summary, body: requestBody, attachments: files)

        case let .failure(rejection):
            attachmentNotices = [rejection.message]
            return nil
        }
    }

    var body: some View {
        let groups = store.snapshot?.repositoryGroups ?? []
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                Group {
                    Section("依頼先") {
                        Picker("アプリ", selection: $repositoryID) {
                            Text("選んでください").tag(TargetRepository.ID?.none)
                            // organization ごとの見出しで分ける（同じ名前のリポジトリが別の organization にあっても見分けられる）
                            ForEach(groups) { group in
                                Section(group.owner) {
                                    ForEach(group.repositories) { repository in
                                        Text(repository.appName).tag(Optional(repository.id))
                                    }
                                }
                            }
                        }
                        if let repository = store.repository(repositoryID) {
                            AppHeaderView(repository: repository) {
                                OwnerLabel(repository: repository)
                            }
                        }
                    }
                    Section("作りたいもの") {
                        // Mac の Form では名前が入力欄の左に並んで欄が狭くなるので、名前は隠して入力欄の中に出す
                        TextField("要約（例: 週ごとのまとめ通知）", text: $summary, prompt: Text("要約（例: 週ごとのまとめ通知）"))
                            .labelsHidden()
                            .focused($isEditing)
                            .attachmentDropExcluded()
                        TextField("依頼の内容", text: $requestBody, prompt: Text("依頼の内容"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(4...12)
                            .focused($isEditing)
                            .attachmentDropExcluded()
                    }
                    // 送信中は一覧を変えさせない（送れたら閉じるので、送信中に足したものが黙って消えないように）
                    AttachmentPickerSection(attachments: $attachments, notices: $attachmentNotices, isDisabled: sending.isSending)
                }
                .disabled(sending.isSending)
            }
            .formStyle(.grouped)
            // macOS では、フォームのどこに落としても添付になる（Discussion #784）
            .attachmentDropTarget(attachments: $attachments, notices: $attachmentNotices) { !sending.isSending }
            .pastelBackground()
            .navigationTitle("新しい依頼")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("送る", isSending: sending.isSending) { submit() }
                        .disabled(!canSend)
                }
            }
            .confirmationDialog(
                "さきほど同じ依頼を送りました",
                isPresented: Binding { duplicateSentAt != nil } set: { if !$0 { duplicateSentAt = nil } },
                titleVisibility: .visible,
                presenting: duplicateSentAt
            ) { _ in
                Button("もう一度送る") { submit(confirmed: true) }
            } message: { sentAt in
                Text("\(sentAt.formatted(date: .omitted, time: .shortened)) に、同じアプリ・要約・内容・添付の依頼を送っています。もう一度送ると、別の epic がもう 1 つできます")
            }
            .keyboardDoneButton($isEditing)
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    /// 送る。同じ内容の依頼を少し前に送っていたら、先に確かめる
    private func submit(confirmed: Bool = false) {
        guard !sending.isSending, let intent = makeIntent() else {
            return
        }
        if !confirmed, let sentAt = store.recentlySentRequest(intent) {
            duplicateSentAt = sentAt
            return
        }
        isEditing = false
        Task {
            guard case .sent(let receipt) = await sending.send(intent, in: store) else {
                return
            }
            dismiss()
            // 送った依頼は、司令塔が受け取る前から epic として出ているので、そこへ移る（読めていなければ閉じるだけ）
            if let epicID = receipt.requestedEpicID, store.epic(epicID) != nil {
                navigator.open(.epic(epicID), in: .progress)
            }
        }
    }
}
